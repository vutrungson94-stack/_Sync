#Requires -Version 5.1
<#
.SYNOPSIS
    Zero-dependency sanity checks pushed files must survive before they ship.

.DESCRIPTION
    Two failure classes reach GitHub as a red run and produce nothing locally:
    a text file mangled by PowerShell's default encoding, and a YAML file that
    cannot parse. Both look like ordinary bytes to a sync tool.

    1. Encoding guard (Find-TextSanityIssue)
       PowerShell on Windows writes UTF-16 (every code point followed by a
       0x00 byte) when a script appends with `>>` / Out-File / Add-Content
       without an -Encoding argument. A UTF-8 text file that gains a NUL byte
       is corrupt; that exact bug shipped a broken GitHub workflow. The guard
       fails on the first NUL byte and warns when the UTF-8 decode produced
       U+FFFD replacement characters (the "C?ng c?" mangling).

    2. YAML structural scan (Find-YamlSanityIssue)
       The two mistakes editor tooling actually produces:
         - a mapping key repeated inside the same mapping (GitHub's parser
           refuses to start a workflow with duplicate keys);
         - tab characters in indentation (YAML allows spaces only).
       The scan walks block structure - indent levels, sequence items, block
       scalars - with hand-written rules, no parser module. It is scoped to
       what makes a file unusable, not a full YAML grammar. Projects that
       ship their own parser keep it: the pre-push gate also runs the
       project's own validation script when one exists.

    Fatal issues carry Severity 'Error'; 'Warning' never blocks a push.
#>

Set-StrictMode -Version 2.0

# File types that are plain text in this ecosystem. Byte scans only run on
# these: a NUL byte inside a zip or a png is normal, inside a yml it is a bug.
$script:DefaultTextExtensions = @(
    '.ps1', '.psm1', '.psd1', '.psm1',
    '.yml', '.yaml', '.json', '.xml', '.md', '.txt', '.rst',
    '.html', '.css', '.scss', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx',
    '.sh', '.bat', '.cmd', '.sql', '.cs', '.py', '.rb', '.go', '.rs', '.java',
    '.gitignore', '.gitattributes', '.editorconfig', '.env', '.npmrc',
    '.cfg', '.ini', '.toml', '.conf', '.properties', '.svg', '.csv'
)

function Find-TextSanityIssue {
    <#
    .SYNOPSIS
        Byte/decoding-level problems for one text file.

    .OUTPUTS
        Array of PSCustomObject: File, Severity, Line, Code, Message
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 64)][int]$MaxFileMB = 5
    )

    $issues = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $issues }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt ($MaxFileMB * 1MB)) {
        return @([PSCustomObject]@{
            File = $Path; Severity = 'Warning'; Line = 0
            Code = 'file-too-large'
            Message = "File is $([math]::Round($item.Length / 1MB, 1)) MB (> $MaxFileMB MB); byte scan skipped."
        })
    }

    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)

    # Corruption signature #1: a NUL byte inside a text file. UTF-16LE writes
    # every character as <char><0x00>, so even one relic means a UTF-16
    # writer touched the file.
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0) {
            $issues += [PSCustomObject]@{
                File = $Path; Severity = 'Error'; Line = 0
                Code = 'nul-byte'
                Message = "NUL (0x00) byte at file offset $i - a UTF-16 writer touched this file (PowerShell >> / Out-File without -Encoding writes UTF-16; use Set-Content -Encoding utf8)."
            }
            break
        }
    }

    # Corruption signature #2: invalid UTF-8 bytes decode to U+FFFD. Not
    # fatal on its own (one stray byte should not block a push), but it is
    # the visible symptom of an encoding switch mid-file.
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($decoded.IndexOf([char]0xFFFD) -ge 0) {
        $issues += [PSCustomObject]@{
            File = $Path; Severity = 'Warning'; Line = 0
            Code = 'suspect-utf8'
            Message = "Decoded content contains U+FFFD replacement characters - mixed/wrong encoding inside this file."
        }
    }

    return $issues
}

function Find-YamlSanityIssue {
    <#
    .SYNOPSIS
        Structure-level YAML problems for one file.

    .DESCRIPTION
        Walks YAML block structure without a parser module:

          - 'duplicate-key': the same mapping key twice inside one mapping.
            Sequence items (`- key: value`) each open a fresh mapping, so the
            same key across different list items stays legal.
          - 'tab-indent': a tab in the leading whitespace.

        Block scalars (`key: |`) swallow everything that is indented deeper
        than the key, so shell bodies and folded text never become fake
        mapping keys. Sibling mappings after a dedent are separated by the
        stack walk, not by line adjacency.

    .OUTPUTS
        Array of PSCustomObject: File, Severity, Line, Code, Message
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 64)][int]$MaxFileMB = 5
    )

    $issues = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $issues }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt ($MaxFileMB * 1MB)) {
        return @([PSCustomObject]@{
            File = $Path; Severity = 'Warning'; Line = 0
            Code = 'file-too-large'
            Message = "File is $([math]::Round($item.Length / 1MB, 1)) MB (> $MaxFileMB MB); YAML scan skipped."
        })
    }

    $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0) {
            $issues += [PSCustomObject]@{
                File = $Path; Severity = 'Error'; Line = 0
                Code = 'nul-byte'
                Message = "NUL (0x00) byte at file offset $i - not parseable YAML."
            }
            return $issues
        }
    }

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $lines = @($text -split "`r?`n")

    # Mapping stack: each entry is one open mapping with its indent level.
    # Keys are case-sensitive (YAML semantics; 'name' and 'Name' differ).
    $frames = New-Object System.Collections.ArrayList
    $skipIndent = -1      # inside a block scalar: exit at indent <= skipIndent
    $tabReported = $false

    $keyRegex = '^(?<key>[A-Za-z0-9_./-]+|"[^"]*"|''[^'']*'')\s*:\s*(?<value>.*)$'
    $blockScalarRegex = '^[|>][+\-=0-9]*\s*(#.*)?$'

    function New-Frame {
        param([int]$Indent)
        $null = $frames.Add([PSCustomObject]@{
            Indent = $Indent
            Keys = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
        })
    }

    function Get-PlainKey {
        param([string]$RawKey)
        if ($RawKey.Length -ge 2 -and ($RawKey.StartsWith('"') -or $RawKey.StartsWith("'"))) {
            return $RawKey.Substring(1, $RawKey.Length - 2)
        }
        return $RawKey
    }

    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++

        # Leading whitespace: tabs are a structure mistake in YAML; count one
        # tab as two spaces so the walk survives to find more problems.
        $indent = 0
        $scan = 0
        while ($scan -lt $line.Length -and ($line[$scan] -eq 0x20 -or $line[$scan] -eq 0x09)) {
            if ($line[$scan] -eq 0x09) {
                if (-not $tabReported) {
                    $issues += [PSCustomObject]@{
                        File = $Path; Severity = 'Error'; Line = $lineNo
                        Code = 'tab-indent'
                        Message = "Tab character in indentation - YAML permits spaces only."
                    }
                    $tabReported = $true
                }
                $indent += 2
            } else {
                $indent++
            }
            $scan++
        }
        $content = $line.Substring($scan)

        # Blank lines and comments never affect block structure - but only
        # OUTSIDE a block scalar, where `#` is content, not a YAML comment.
        if ($skipIndent -lt 0) {
            $trimmedContent = $content.Trim()
            if ($trimmedContent.Length -eq 0 -or $trimmedContent.StartsWith('#')) { continue }
        }

        # Inside a block scalar: a shallow (or blank-terminated) line ends it.
        if ($skipIndent -ge 0) {
            if ($content.Trim().Length -eq 0 -or $indent -gt $skipIndent) { continue }
            $skipIndent = -1
        }

        # Document separators restart the mapping walk.
        if ($content -eq '---' -or $content -eq '...') {
            $null = $frames.Clear()
            continue
        }

        # Bracket-flow style (JSON written as YAML): a line that is nothing
        # but an opening brace/bracket opens a fresh container, and its close
        # must re-separate sibling containers, otherwise every item's keys
        # would pile into one mapping and report phantom duplicates.
        $needle = $content.Trim().TrimEnd(',', ' ', "`t")
        if ($needle -eq '{' -or $needle -eq '[') {
            New-Frame -Indent $indent
            continue
        }
        if ($needle -eq '}' -or $needle -eq ']') {
            while ($frames.Count -gt 0 -and $frames[$frames.Count - 1].Indent -ge $indent) {
                $null = $frames.RemoveAt($frames.Count - 1)
            }
            continue
        }

        if ($content.StartsWith('-') -and ($content.Length -eq 1 -or $content.Substring(1, 1) -in @(' ', "`t"))) {
            # Sequence item. '- key: value' places keys at the content indent
            # (dash + following spaces). Sibling items each own a mapping, so
            # every frame at or deeper than the item's content indent closes.
            $rest = $content.Substring(1).TrimStart()
            $contentIndent = $indent + ($content.Length - $rest.Length)
            while ($frames.Count -gt 0 -and $frames[$frames.Count - 1].Indent -ge $contentIndent) {
                $null = $frames.RemoveAt($frames.Count - 1)
            }
            if ($rest -match $keyRegex) {
                $effIndent = $contentIndent
                while ($frames.Count -gt 0 -and $frames[$frames.Count - 1].Indent -gt $effIndent) {
                    $null = $frames.RemoveAt($frames.Count - 1)
                }
                if ($frames.Count -eq 0 -or $frames[$frames.Count - 1].Indent -lt $effIndent) {
                    New-Frame -Indent $effIndent
                }
                $frame = $frames[$frames.Count - 1]
                $key = Get-PlainKey $Matches['key']
                if ($key -ne '<<') {
                    if (-not $frame.Keys.Add($key)) {
                        $issues += [PSCustomObject]@{
                            File = $Path; Severity = 'Error'; Line = $lineNo
                            Code = 'duplicate-key'
                            Message = "Mapping key '$key' repeats inside the same mapping - GitHub refuses to start a workflow with duplicate keys."
                        }
                    }
                }
                if ($Matches['value'] -and $Matches['value'].Trim() -match $blockScalarRegex) {
                    $skipIndent = $effIndent
                }
            }
            continue
        }

        if ($content -match $keyRegex) {
            $effIndent = $indent
            # Dedent walks out of deeper mappings only. A frame at the SAME
            # indent is this key's own mapping and must survive, or two keys
            # of one mapping could never collide in it.
            while ($frames.Count -gt 0 -and $frames[$frames.Count - 1].Indent -gt $effIndent) {
                $null = $frames.RemoveAt($frames.Count - 1)
            }
            if ($frames.Count -eq 0 -or $frames[$frames.Count - 1].Indent -lt $effIndent) {
                New-Frame -Indent $effIndent
            }
            $frame = $frames[$frames.Count - 1]
            $key = Get-PlainKey $Matches['key']
            if ($key -ne '<<') {
                if (-not $frame.Keys.Add($key)) {
                    $issues += [PSCustomObject]@{
                        File = $Path; Severity = 'Error'; Line = $lineNo
                        Code = 'duplicate-key'
                        Message = "Mapping key '$key' repeats inside the same mapping - GitHub refuses to start a workflow with duplicate keys."
                    }
                }
            }
            if ($Matches['value'].Trim() -match $blockScalarRegex) {
                $skipIndent = $effIndent
            }
            continue
        }
        # Everything else (plain scalars, flow collections, directives) has
        # no mapping identity to collide.
    }

    return $issues
}

function Test-TextSanity {
    <#
    .SYNOPSIS
        Encoding-level sanity for one text file. $true when clean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxFileMB = 5
    )
    # The @() reintroduces the array the pipeline unrolls: a single object has
    # no .Count, and StrictMode turns that into a hard error.
    $fatal = @(@(Find-TextSanityIssue -Path $Path -MaxFileMB $MaxFileMB) | Where-Object { $_.Severity -eq 'Error' })
    return ($fatal.Count -eq 0)
}

function Test-YamlSanity {
    <#
    .SYNOPSIS
        Encoding + structure sanity for one YAML file. $true when parseable.
    .DESCRIPTION
        Returns $true only when no Severity 'Error' issue exists (warnings
        such as suspect-utf8 do not fail the check).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxFileMB = 5
    )
    $encoding = @(Find-TextSanityIssue -Path $Path -MaxFileMB $MaxFileMB)
    $structure = @(Find-YamlSanityIssue -Path $Path -MaxFileMB $MaxFileMB)
    $fatal = @( @($encoding + $structure) | Where-Object { $_.Severity -eq 'Error' } )
    return ($fatal.Count -eq 0)
}

function Get-DefaultTextExtension {
    <#
    .SYNOPSIS
        Default extension list the byte-level guard treats as text.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # The comma keeps the array an array under PowerShell unrolling.
    return ,@($script:DefaultTextExtensions)
}

Export-ModuleMember -Function @(
    'Find-TextSanityIssue', 'Find-YamlSanityIssue',
    'Test-TextSanity', 'Test-YamlSanity',
    'Get-DefaultTextExtension'
)
