# InkStain Screensaver for Kindle

Kindle 原生阅读统计锁屏壁纸，在锁屏时渲染 KOReader 墨痕风格的阅读小票。

## 功能

- 锁屏自动渲染阅读统计小票（墨痕/胶片两种风格）
- 显示近7天阅读时长、书单 Top5、每日阅读折线图
- 显示书籍进度、电量、日期、诗词名言
- 伪二维码和条码装饰
- 开机自启，无需手动触发
- 唤醒自动恢复桌面

## 适配

- Kindle Scribe 2022 (1860×2480, 300dpi)
- 系统 5.19.6，越狱方案 Véra
- 依赖：系统级 FBInk (`/var/local/kmc/bin/fbink`) + CJK 字体

## 安装

### 前置条件

- Kindle 已通过 Véra/KPM 越狱
- 系统级 FBInk 已安装（`/var/local/kmc/bin/fbink`）
- 至少一个 CJK 字体已安装在 Kindle 上（`/mnt/us/fonts/` 或系统字体目录）

### 方法一：RUNME 一键安装

1. USB 连接 Kindle
2. 在 Kindle 根目录创建文件夹 `native-reading-time-package`
3. 将 `combined-package/` 目录下的**所有文件**复制到该文件夹中
4. 将 `combined-package/RUNME.sh` 复制到 Kindle 根目录（`/mnt/us/RUNME.sh`）
5. 确保根目录 `fonts/` 文件夹中有 CJK 字体（如 `京華老宋体v3.0.ttf`）——安装脚本也会自动搜索系统字体
6. 弹出 USB
7. 在 Kindle 搜索栏输入 `;log runme`
8. 等待安装完成，重启 Kindle

### 安装验证

重启后按电源键锁屏，应看到墨痕风格阅读小票。

也可通过快速测试脚本验证（无需锁屏）：

```sh
sh /mnt/us/reading-time/bin/inkstain-quicktest.sh
```

## 风格切换

编辑 Kindle 上的 `/mnt/us/reading-time/inkstain-style.conf`：

```
style=inkstain    # 墨痕壁纸（默认）
style=film        # 胶片票根
style=random      # 随机
style=alternate   # 轮流
```

## 卸载

1. 将 `uninstall-RUNME.sh` 复制到 Kindle 根目录，改名为 `RUNME.sh`
2. 搜索栏输入 `;log runme`
3. 重启 Kindle

卸载会删除：
- Upstart 服务配置 (`/etc/upstart/inkstain-screensaver.conf`, `/etc/upstart/native-reading-time.conf`)
- 所有脚本和数据 (`/mnt/us/reading-time/`)

## 文件说明

### combined-package/ 核心安装包

| 文件 | 说明 |
|------|------|
| `RUNME.sh` | 安装入口脚本，通过 `;log runme` 触发 |
| `install-combined.sh` | 主安装逻辑（阅读记录 + 锁屏壁纸） |
| `inkstain-render.sh` | 渲染脚本，用 FBInk 绘制锁屏画面 |
| `inkstain-listener.sh` | 监听脚本，轮询电源状态触发渲染 |
| `inkstain-quicktest.sh` | 快速测试脚本，不锁屏直接渲染 |
| `film-step.sh` | 胶片风格逐步调试脚本（开发用） |
| `inkstain-screensaver.conf` | Upstart 服务配置（墨痕监听） |
| `native-reading-time.conf` | Upstart 服务配置（阅读记录守护进程） |
| `native-reading-time-daemon.sh` | 原生阅读时长记录守护进程 |
| `inkstain-style.conf` | 风格配置文件 |
| `reading-dashboard.sh` | 阅读仪表盘（可选） |
| `reading-insights-touch.lua` | 触摸阅读统计（可选） |
| `FONT-LICENSE.txt` | 字体许可 |

### 根目录辅助文件

| 文件 | 说明 |
|------|------|
| `uninstall-RUNME.sh` | 卸载脚本，改名为 `RUNME.sh` 后执行 |
| `LICENSE` | GPLv3 许可文件 |

## 技术架构

```
开机 → Upstart 启动两个服务
  ├── native-reading-time (守护进程)
  │     └── 监听 LIPC 属性，记录阅读时长到 reading-time.tsv
  └── inkstain-screensaver (监听脚本)
        └── 每2秒轮询 com.lab126.powerd state
              ├── screenSaver → 等5秒 → 清屏 → 调用渲染脚本
              │     └── 3秒后验证状态，仍在屏保则重新渲染
              └── active → 杀渲染进程 → 框架恢复桌面
```

渲染流程：
1. 单次清屏 (`fbink -k -f -W GC16`)
2. 所有绘图用 `-b` 标志写入帧缓冲（不刷新屏幕）
3. 最终一次 `fbink -s -f -W GC16` 统一刷新显示

## 数据源

- `reading-time.tsv`：阅读时长记录（由守护进程写入）
  - 格式：`date \t book_id \t seconds \t title`
- `cc.db`：Kindle 原生书籍进度数据库（只读）
- `com.lab126.powerd` LIPC 属性：电源状态、电量

## 已知限制

- 锁屏瞬间会短暂闪现原生壁纸（框架先画再被清屏覆盖）
- 开机后框架初始化期间可能有几秒白屏
- 不支持 KOReader 的阅读数据（仅原生阅读器）

## 许可

GPLv3
