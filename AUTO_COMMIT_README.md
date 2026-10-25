# AutoCommit System - Auto Smart Commit (Enterprise, Cross-Platform)

## ✅ Tính năng đã triển khai

### 1. **AutoCommit.psm1** (`Modules/AutoCommit.psm1`)
- `Start-AutoCommit`: Hàm chính tự động commit dựa trên config
- `Test-SmartSecretBlocking`: Kiểm tra secret patterns trên staged files
- `Get-SmartAutoStageChanges`: Lọc file theo extension và directory rules
- `Invoke-AutoCleanup`: Dọn dẹp junk file tự động

### 2. **gsync-pre-commit.ps1** - Được nâng cấp
- Smart auto-staging (chỉ staging file user-modified)
- Secret blocking (dựa trên config.security.secretPatterns)
- Webhook notification khi phát hiện vi phạm

### 3. **gsync-pre-push.ps1** - Được nâng cấp  
- Branch protection check
- Large file detection + webhook notification
- Auto webhook notification trước khi push

### 4. **gsync.config.json** - Được mở rộng
```json
"autoCommit": {
    "enabled": true,
    "smartStaging": true,
    "commitMessageTemplate": "[auto] {0}",
    "excludedExtensions": [".dll", ".exe", ".pdb"],
    "excludedDirectories": ["bin/", "obj/", "node_modules/"]
},
"security": {
    "enabled": true,
    "blockOnMatch": true,
    "secretPatterns": ["(?i)(sk-or-v1-[a-z0-9]+)", "(?i)(ghp_[a-z0-9]{36})", ...]
}
```

## 🎯 Cách hoạt động

1. **Khi `git commit`**:
   - Hook `pre-commit` được kích hoạt tự động
   - Nếu `autoCommit.enabled=true`: hệ thống tự động lọc và staging file
   - Secret scanning chặn commit nếu phát hiện mẫu nhạy cảm
   - Webhook notification gửi cảnh báo nếu cần

2. **Khi `git push`**:
   - Hook `pre-push` kiểm tra branch protection
   - Large file detection + cảnh báo
   - Webhook notification gửi trạng thái

## 🔧 Cấu hình

Chỉnh sửa `gsync.config.json`:

```json
{
    "autoCommit": {
        "enabled": true,
        "smartStaging": true,
        "commitMessageTemplate": "[auto] {0}"
    },
    "security": {
        "enabled": true,
        "blockOnMatch": true,
        "secretPatterns": [...]
    }
}
```

## 📊 Test

File test: `Tests/AutoCommit.Tests.ps1`

---

**Trạng thái**: ✅ Hoàn thành - Hệ thống Auto Smart Commit đang hoạt động.