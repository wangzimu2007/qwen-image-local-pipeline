# 关思考代理：本地模型提速 2~3 倍

## 问题

本地聊天模型（Strata 8080，Qwen3.8-Flash-Next）**默认开着思考模式**。实测一个正常任务：

| 场景 | 正文首字 | 正文 | 推理词 | 总耗时 |
|---|---|---|---|---|
| 思考开（直连 8080）| 2.36s | 148 词 | **176 词** | 3.62s |
| 思考关（经代理）| 4.28s | **286 词** | **0 词** | 4.28s |

更糟的是**预算被吃光**的情况（max_tokens=600）：

```
直连（思考开）   正文 0 词   推理 577 词   4.94s   ← 全是思考，正文一个字没有
直连再测        正文 0 词   推理 570 词   5.25s   ← 同上
经代理（思考关）  正文 519 词  推理 0 词    4.50s   ← 直接给答案
```

正文为空 → 上层（DSH）收不到回复 → 重试 → 又一轮思考。这就是"**一直在思考**"的真相。

**工具调用场景**（带 tools 数组，模拟真实 agent 回合）：

| 场景 | 耗时 | 工具调用 | 正文 | 推理 |
|---|---|---|---|---|
| 直连 8080 | 7.39s | 1 个 ✅ | 0 字 | 144 字 |
| **经代理 8081** | **3.28s** | 1 个 ✅ | 58 字 | **0 字** |

→ **2.25 倍**，且工具调用仍然正确。

## 方案：本地透明代理

```
DSH ──▶ 127.0.0.1:8081 (think-off-proxy.py) ──▶ 127.0.0.1:8080 (Strata)
              给 /v1/chat/completions 补：
              "chat_template_kwargs": {"enable_thinking": false}
              "reasoning_effort": "none"
```

`scripts/think-off-proxy.py`（纯标准库，无依赖）：

```powershell
python think-off-proxy.py                                          # 8081 → 8080，关思考
python think-off-proxy.py --keep-thinking                           # 纯转发（对比用）
python think-off-proxy.py --port 8082 --upstream 127.0.0.1:11434    # 也可以代理 Ollama
```

然后 DSH 的 `strata-local` 把 baseURL 改成 `http://127.0.0.1:8081/v1`。

## 为什么不直接改 DSH 配置

DSH 的 provider 配置里确实有 `compat.thinkingFormat: qwen`（发 `enable_thinking`）这类字段，
但自定义 provider 的 zod 校验规则在打包后的 asar 里不可见——**猜错字段会让 DSH 起不来**。
代理方案只改一个 `baseURL`，字段 100% 合法，随时可回滚。

## 验证过的行为

| 检查项 | 结果 |
|---|---|
| `/v1/models` 经代理 | ✅ 正常返回 |
| `/v1/chat/completions` 流式 | ✅ 正常，推理词 0 |
| **工具调用（tools + tool_choice=auto）** | ✅ 正常，1 个 tool_call |
| 代理被杀后自动恢复 | ✅ watchdog 端口守护，秒级拉起 |
| 关闭思考后的输出质量 | ✅ 正文更完整（思考会挤占预算）|

## 运维

- 代理常驻：快捷方式「思考代理 - 启动」，已加开机自启
- **watchdog 端口守护**：`D:\tools\win-layout\watchdog.ps1` 每 30 秒检查 8081，
  掉了自动重启（实测：杀掉后 1 秒内拉起）
- 日志：`D:\qwen-image-2.1\.think-proxy.log`
- 排查顺序：8081 在不在 → 8080 在不在 → 请求 `/v1/models`
- 恢复思考：代理加 `--keep-thinking`，或把 baseURL 改回 8080

## 局限

- 关掉思考后，**复杂多步推理**可能略差（模型少了草稿环节）；实测工具调用与分类总结不受影响
- Ollama 的 OpenAI 兼容端点对 `enable_thinking` 的处理未验证（且 Ollama 与 Strata 不能同时占显存），暂未接入
