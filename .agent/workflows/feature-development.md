---
description: 標準功能開發流程
---

# 功能開發 Workflow

## 步驟

### 1. 開始前準備
閱讀 `FEATURES.md` 了解當前所有功能，確保不會與現有功能衝突。

### 2. 實作功能
根據需求實作新功能或修改現有功能。

### 3. 測試驗證
// turbo
執行靜態分析：
```bash
flutter analyze
```

// turbo
建置應用程式：
```bash
flutter build macos --release
```

### 4. 更新文檔
檢查功能變更，如有需要更新 `FEATURES.md`：
- 新增功能：添加新的功能說明
- 修改功能：更新對應的描述
- 刪除功能：移除相關說明
- 每個功能保持 2 行精簡描述

### 5. 提交變更
提交所有變更到 git，包含 `FEATURES.md`（如有更新）。

### 6. 建立發布包
// turbo
創建新的 DMG 檔案：
```bash
./create_dmg.sh
```

## 注意事項

- 確保 `FEATURES.md` 永遠與實際功能同步
- 每次提交都要包含有意義的 commit message
- DMG 檔案不需要提交到 git（已在 .gitignore 中）
