# Dictate：本机流式听写（浮层 + 松手插入）

日期：2026-08-15
状态：本机 v1 已实现

## 目标

按住热键说话，浮层里实时出字（PARTIAL 覆盖、FINAL 落下）。松开后按持久化设置把定稿一次性送回开始听写时捕获的焦点，或只复制到剪贴板。Esc 取消、不提交。

不做 Typeless 式 LLM 润色，不做系统级「在别人输入框里逐帧覆盖」。

## 架构

```
Right Option 按下
    → 等待 0.16 秒（短按 / Option 快捷键不触发）
    → 创建独立 UtteranceTransaction
    → 捕获前台 PID + AXFocusedUIElement
    → 创建本轮专属 SpeechRunner 并开麦
    → 浮层显示 displayText

PARTIAL → 只替换 volatile
FINAL   → 追加 committed，清空 volatile

Right Option 松开
    → 先登记 finish，阻止尚在启动的任务继续开麦
    → 结束输入并 finalizeAndFinishThroughEndOfInput
    → 排空结果流，只取 FINAL（dangling partial 丢弃）
    → 翻译开启时等待已调度的 FINAL 翻译，硬上限 2 秒
    → 生成「原文 + 已完成译文」；超时 / 失败则回退原文
    → 插入模式：校验 PID + AX 焦点仍是原目标
        → 完整保存剪贴板 item/type，尝试一次 ⌘V
        → changeCount 未变化时恢复剪贴板
    → 复制模式：只把完整结果写入剪贴板，不模拟按键

Esc → cancel，不插入
```

## 组件

| 单元 | 职责 |
|---|---|
| `DictateCore.TextJoiner` | 中英混排拼接（CJK 之间不加空格） |
| `DictateCore.DictateSession` | 纯状态机：idle / listening / 插入文本 |
| `DictateCore.TalkGesture` | 右 Option 的等待、快捷键抑制、停止与取消状态机 |
| `DictateSettings` | 保存中文 / English 识别 locale、翻译开关与完成方式 |
| `TranslationBatch` | 等待 FINAL 翻译；独立超时信号，不等待不响应取消的后台任务 |
| `SpeechRunner` | SpeechAnalyzer 麦克风流，输出 hypothesis |
| `OverlayPanel` | 非激活浮层，只显示，不抢焦点 |
| `HotkeyMonitor` | 右 Option 按住说话；Esc 取消 |
| `PasteInserter` | 插入模式验证原焦点并有条件还原剪贴板；复制模式只写剪贴板 |

## 约束

- 独立仓库，不放进背单词
- 识别引擎：系统 SpeechAnalyzer（macOS 26+），默认 locale `zh-CN`
- 默认翻译并插入原文 + 译文；菜单可关闭，或用 `--no-translate` 临时覆盖
- 中文 / English 识别语言可从菜单切换并持久化
- 插入 / 只复制可从菜单切换并持久化，或用 `--insert` / `--copy` 临时覆盖
- 默认热键：右 Option（避开中文输入法 Control+Space / Spotlight）
- 无辅助功能权限时：文本留在剪贴板，浮层提示手动粘贴
- 音频不出本机

## 非目标（v1）

- 在第三方输入框内闪字
- 自动发送 / 回车
- 云端 ASR、Nemotron、SenseVoice 校正
- 多语言热切换 UI

## 诚实边界

- Accessibility 可验证目标是否仍一致，但模拟 `⌘V` 无法证明第三方应用最终修改成功；契约是“对已验证目标最多尝试一次”。
- AX 不可用或焦点变化时只复制；安全输入框既不粘贴也不复制。最近一次非安全结果可从菜单重新复制。
- 翻译使用本机 Apple Translation；语言包缺失时需要在系统设置中安装。
- 当前 `.app` 是本机 ad-hoc 签名构建，不是可公证分发包。
