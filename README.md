# minecraft-backup-cloud-sync

將本地 Minecraft FTB 備份資料夾持續同步到 Cloudflare R2。

## 需求

- [rclone](https://rclone.org/install/)
- python3
- bc

## 設定 Cloudflare R2

1. Cloudflare Dashboard → R2 → **Manage R2 API Tokens** → 建立 token（權限選 Object Read & Write）
2. 執行 `rclone config`，新增一個 remote：

   | 欄位 | 值 |
   |------|----|
   | name | `r2`（任意） |
   | Storage | `s3` |
   | provider | `Cloudflare` |
   | access_key_id | R2 token 的 Access Key ID |
   | secret_access_key | R2 token 的 Secret Access Key |
   | endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` |

3. 測試連線：`rclone lsd r2:your-bucket`

## 用法

```bash
./main.sh \
  --local-dir /home/demo-user/star-technology/backups \
  --remote r2:your-bucket/ftbbackup \
  --backup-dir r2:your-bucket/ftbbackup-deleted \
  --max-size 8 \
  --interval 1800
```

### 選項

| 選項 | 預設 | 說明 |
|------|------|------|
| `-l, --local-dir` | 必填 | 本地備份資料夾路徑（建議用絕對路徑避免不可預測的行為） |
| `-r, --remote` | 必填 | 備份同步目的地（主要儲存路徑），例：`r2:bucket/ftbbackup` |
| `-b, --backup-dir` | 必填 | 刪除檔案的保留區，本地刪掉的備份會移到這裡而非直接刪除（不可與 `--remote` 相同），例：`r2:bucket/ftbbackup-deleted` |
| `-m, --max-size` | `8` | 遠端容量上限（GB） |
| `-i, --interval` | `1800` | 每次 sync 間隔（秒） |
| `-M, --max-missing` | `3` | 遠端比本地多幾個檔案才觸發 abort |
| `-d, --dry-run` | — | 模擬執行，不實際操作 |

## 保護機制

腳本在每次 sync 前執行兩項檢查，任一失敗都會**跳過本次 sync，等待下次間隔後重試**（不會停止整個腳本）。

### 容量上限（`--max-size`）

每次 sync 前查詢遠端已使用容量。

| 情況 | 行為 |
|------|------|
| 已用容量 < 上限 | 正常 sync |
| 已用容量 ≥ 上限 | 印 WARN，跳過本次 sync，需手動清理 `--remote` 或調高 `--max-size` |
| rclone 查詢失敗 | 印 ERROR，跳過本次 sync |

### 檔案差異保護（`--max-missing`）

比對遠端與本地的檔案列表，防止本地意外誤刪後把刪除同步上去。

| 情況 | 行為 |
|------|------|
| 遠端比本地多的檔案數 ≤ `--max-missing` | 視為正常 rotate，這些檔案會被移到 `--backup-dir` |
| 遠端比本地多的檔案數 > `--max-missing` | 印 WARN 並列出差異檔案，跳過本次 sync |

`--max-missing` 預設 3，若備份 rotate 策略保留的舊檔較多，請調高此值。

### 刪除保護（`--backup-dir`）

使用 `rclone sync --backup-dir`，本地已刪除的舊備份不會從遠端直接刪除，而是移到 `--backup-dir` 指定的目錄保留。

## 常駐執行

### systemd（推薦）

建立 `/etc/systemd/system/minecraft-backup.service`：

```ini
[Unit]
Description=Minecraft FTB Backup Cloud Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User= # 必填：rclone 設定檔在使用者家目錄，root 執行會找不到
ExecStart=/path/to/main.sh \
  --local-dir /home/demo-user/star-technology/backups \
  --remote r2:your-bucket/ftbbackup \
  --backup-dir r2:your-bucket/ftbbackup-deleted \
  --max-size 8 \
  --interval 1800
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
```

啟用並啟動：

```bash
sudo systemctl daemon-reload
sudo systemctl enable minecraft-backup
sudo systemctl start minecraft-backup
```

查看狀態與日誌：

```bash
sudo systemctl status minecraft-backup
sudo journalctl -u minecraft-backup -f
```

### nohup（臨時使用）

```bash
nohup ./main.sh \
  --local-dir /home/demo-user/star-technology/backups \
  --remote r2:your-bucket/ftbbackup \
  --backup-dir r2:your-bucket/ftbbackup-deleted \
  > ~/minecraft-backup.log 2>&1 &

echo "PID: $!"
```

停止：

```bash
kill <PID>
```
