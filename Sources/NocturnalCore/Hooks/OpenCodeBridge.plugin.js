// >>> nocturnal-managed
// nocturnal-opencode-bridge v3 — OpenCode → Nocturnal bridge
// Phase 2 fix: use permission.ask hook + serverUrl + correct SDK method name.
// Fail-open: never throw into OpenCode.
// <<< nocturnal-managed

import net from "node:net"
import { randomUUID } from "node:crypto"
import { appendFileSync } from "node:fs"

const SOCKET_PATH = "__NOCTURNAL_SOCKET__"
const CONNECT_TIMEOUT_MS = 500
const DECISION_TIMEOUT_MS = 120000
const SOURCE = "opencode"
const DEBUG_LOG = "/tmp/nocturnal-opencode-bridge.log"

function debug(msg, extra) {
  try {
    const line =
      new Date().toISOString() +
      " " +
      msg +
      (extra !== undefined ? " " + JSON.stringify(extra) : "") +
      "\n"
    appendFileSync(DEBUG_LOG, line)
  } catch {}
}

function nowISO() {
  return new Date().toISOString()
}

function pickSessionId(fallbackCwd, ...candidates) {
  for (const value of candidates) {
    if (typeof value === "string" && value.length > 0 && value !== "unknown") return value
    if (value && typeof value === "object") {
      const nested =
        value.id ||
        value.sessionID ||
        value.sessionId ||
        value.session_id ||
        value.session?.id ||
        value.info?.id ||
        value.info?.sessionID
      if (typeof nested === "string" && nested.length > 0 && nested !== "unknown") return nested
    }
  }
  const scope = typeof fallbackCwd === "string" && fallbackCwd.length > 0 ? fallbackCwd : "default"
  return "opencode:" + scope
}

function envelope(eventType, sessionId, payload, raw) {
  return {
    v: 1,
    id: randomUUID(),
    source: SOURCE,
    eventType,
    sessionId: sessionId || "opencode:default",
    timestamp: nowISO(),
    payload: payload || {},
    raw: raw || payload || {},
  }
}

function sendEnvelope(obj) {
  return new Promise((resolve) => {
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      resolve(null)
    }
    let socket
    try {
      socket = net.createConnection({ path: SOCKET_PATH })
    } catch {
      finish()
      return
    }
    const timer = setTimeout(() => {
      try {
        socket.destroy()
      } catch {}
      finish()
    }, CONNECT_TIMEOUT_MS)
    socket.on("connect", () => {
      try {
        socket.write(JSON.stringify(obj) + "\n", () => {
          try {
            socket.end()
          } catch {}
        })
      } catch {
        try {
          socket.destroy()
        } catch {}
        clearTimeout(timer)
        finish()
      }
    })
    socket.on("error", () => {
      clearTimeout(timer)
      finish()
    })
    socket.on("close", () => {
      clearTimeout(timer)
      finish()
    })
  })
}

/** Send PermissionRequest and wait for PermissionDecisionReply. */
function sendAndWaitDecision(obj, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false
    let buf = ""
    let socket = null
    const finish = (value) => {
      if (settled) return
      settled = true
      try {
        if (socket) socket.destroy()
      } catch {}
      resolve(value)
    }
    try {
      socket = net.createConnection({ path: SOCKET_PATH })
    } catch (e) {
      debug("connect failed", String(e))
      finish(null)
      return
    }
    const timer = setTimeout(() => {
      debug("decision timeout")
      finish(null)
    }, timeoutMs || DECISION_TIMEOUT_MS)
    socket.setEncoding("utf8")
    socket.on("connect", () => {
      try {
        socket.write(JSON.stringify(obj) + "\n")
        debug("permission sent", {
          sessionId: obj.sessionId,
          id: obj.payload?.id || obj.payload?.request_id,
        })
      } catch (e) {
        clearTimeout(timer)
        debug("write failed", String(e))
        finish(null)
      }
    })
    socket.on("data", (chunk) => {
      buf += chunk
      const nl = buf.indexOf("\n")
      if (nl === -1) return
      const line = buf.slice(0, nl).trim()
      clearTimeout(timer)
      try {
        const parsed = JSON.parse(line)
        debug("decision reply", parsed)
        finish(parsed)
      } catch (e) {
        debug("reply parse failed", line)
        finish(null)
      }
    })
    socket.on("error", (e) => {
      clearTimeout(timer)
      debug("socket error", String(e))
      finish(null)
    })
    socket.on("close", () => {
      if (!settled) {
        clearTimeout(timer)
        finish(null)
      }
    })
  })
}

function serverUrlString(serverUrl) {
  if (!serverUrl) return null
  try {
    if (typeof serverUrl === "string") return serverUrl
    if (serverUrl.href) return serverUrl.href
    return String(serverUrl)
  } catch {
    return null
  }
}

async function replyOpenCodePermission(client, serverUrl, sessionId, permissionId, response) {
  if (!sessionId || !permissionId || sessionId === "unknown") {
    debug("reply skip bad ids", { sessionId, permissionId })
    return false
  }

  // Correct SDK method name (OpenCode 1.15+): postSessionIdPermissionsPermissionId
  const attempts = [
    async () => {
      if (typeof client?.postSessionIdPermissionsPermissionId === "function") {
        await client.postSessionIdPermissionsPermissionId({
          path: { id: sessionId, permissionID: permissionId },
          body: { response },
        })
        return true
      }
      return false
    },
    async () => {
      // Older / alternate client shapes
      if (typeof client?.postSessionByIdPermissionsByPermissionId === "function") {
        await client.postSessionByIdPermissionsByPermissionId({
          path: { id: sessionId, permissionID: permissionId },
          body: { response },
        })
        return true
      }
      return false
    },
    async () => {
      if (typeof client?.session?.postSessionIdPermissionsPermissionId === "function") {
        await client.session.postSessionIdPermissionsPermissionId({
          path: { id: sessionId, permissionID: permissionId },
          body: { response },
        })
        return true
      }
      return false
    },
  ]

  for (const attempt of attempts) {
    try {
      if (await attempt()) {
        debug("sdk reply ok", { sessionId, permissionId, response })
        return true
      }
    } catch (e) {
      debug("sdk reply err", String(e))
    }
  }

  const bases = []
  const su = serverUrlString(serverUrl)
  if (su) bases.push(su)
  try {
    const cfg = client?.getConfig?.() || client?.config
    if (cfg?.baseUrl) bases.push(cfg.baseUrl)
  } catch {}
  if (process.env.OPENCODE_SERVER) bases.push(process.env.OPENCODE_SERVER)
  if (process.env.OPENCODE_BASE_URL) bases.push(process.env.OPENCODE_BASE_URL)
  bases.push("http://127.0.0.1:4096")

  for (const base of bases) {
    try {
      let root = String(base)
      while (root.endsWith("/")) root = root.slice(0, -1)
      const url =
        root +
        "/session/" +
        encodeURIComponent(sessionId) +
        "/permissions/" +
        encodeURIComponent(permissionId)
      const r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ response }),
      })
      debug("http reply", { url, status: r?.status })
      if (r && r.ok) return true
    } catch (e) {
      debug("http reply err", String(e))
    }
  }
  return false
}

function mapDecisionToOpenCodeResponse(reply) {
  if (!reply || !reply.behavior) return null
  if (reply.behavior === "allow") return "once"
  if (reply.behavior === "deny") return "reject"
  return null
}

function mapDecisionToPluginStatus(reply) {
  if (!reply || !reply.behavior) return null
  if (reply.behavior === "allow") return "allow"
  if (reply.behavior === "deny") return "deny"
  return null
}

function toolPayload(input, output, directory) {
  const tool = input?.tool || input?.name || "tool"
  const args = output?.args || input?.args || input?.input || {}
  const payload = {
    tool_name: tool,
    tool,
    name: tool,
    cwd: directory,
    working_directory: directory,
    args,
    tool_input: args,
  }
  if (typeof args?.command === "string") payload.command = args.command
  if (typeof args?.filePath === "string") payload.file_path = args.filePath
  else if (typeof args?.path === "string") payload.file_path = args.path
  else if (typeof args?.file_path === "string") payload.file_path = args.file_path
  if (typeof args?.query === "string") payload.detail = args.query
  else if (typeof args?.url === "string") payload.detail = args.url
  else if (typeof args?.pattern === "string") payload.detail = args.pattern
  return payload
}

function permissionDetail(perm) {
  if (!perm) return undefined
  if (perm.title) return String(perm.title)
  if (perm.pattern) {
    return Array.isArray(perm.pattern) ? perm.pattern.join(", ") : String(perm.pattern)
  }
  if (perm.patterns) {
    return Array.isArray(perm.patterns) ? perm.patterns.join(", ") : JSON.stringify(perm.patterns)
  }
  if (perm.metadata) return JSON.stringify(perm.metadata)
  return undefined
}

function buildPermissionPayload(perm, cwd, serverUrl) {
  const permissionId = perm.id || perm.requestID || perm.request_id || perm.permissionID
  const tool = perm.type || perm.permission || perm.tool || "permission"
  return {
    cwd,
    working_directory: cwd,
    request_id: permissionId,
    id: permissionId,
    approval_id: permissionId,
    tool,
    tool_name: tool,
    summary: perm.title || tool || "Permission required",
    detail: permissionDetail(perm),
    nocturnalNeedsDecision: true,
    nocturnalDecisionRequestId: permissionId,
    nocturnalDecisionTimeoutSec: 120,
    opencode: true,
    permission: tool,
    opencode_server_url: serverUrlString(serverUrl) || undefined,
  }
}

const handledPermissionIds = new Set()

async function handlePermissionDecision(perm, cwd, client, serverUrl, setOutputStatus) {
  const permissionId = perm?.id || perm?.requestID || perm?.permissionID
  if (!permissionId) {
    debug("permission missing id", perm)
    return
  }
  // De-dupe bus + hook double delivery
  if (handledPermissionIds.has(permissionId)) {
    debug("permission already handled", permissionId)
    return
  }
  handledPermissionIds.add(permissionId)
  if (handledPermissionIds.size > 64) {
    handledPermissionIds.clear()
  }

  const sid = pickSessionId(
    cwd,
    perm.sessionID,
    perm.sessionId,
    perm.session_id,
    perm
  )
  const permPayload = buildPermissionPayload(perm, cwd, serverUrl)
  const env = envelope("PermissionRequest", sid, permPayload, {
    ...perm,
    opencode: true,
    source: "opencode",
  })

  const reply = await sendAndWaitDecision(env, DECISION_TIMEOUT_MS)
  const status = mapDecisionToPluginStatus(reply)
  const response = mapDecisionToOpenCodeResponse(reply)

  if (status && setOutputStatus) {
    try {
      setOutputStatus(status)
    } catch (e) {
      debug("set output status failed", String(e))
    }
  }
  if (response) {
    const ok = await replyOpenCodePermission(client, serverUrl, sid, permissionId, response)
    debug("permission complete", { permissionId, status, response, ok })
  } else {
    debug("permission deferred to OpenCode TUI", { permissionId })
  }
}

export const NocturnalBridge = async ({ directory, worktree, client, serverUrl }) => {
  const cwd = directory || worktree || process.cwd()
  debug("plugin init", { cwd, socket: SOCKET_PATH, serverUrl: serverUrlString(serverUrl) })

  const emit = (eventType, sessionId, payload, raw) =>
    sendEnvelope(envelope(eventType, sessionId, payload, raw)).catch(() => {})

  return {
    // Primary intercept (OpenCode Plugin API) — can set output.status before TUI.
    "permission.ask": async (input, output) => {
      try {
        debug("permission.ask", {
          id: input?.id,
          type: input?.type,
          sessionID: input?.sessionID,
        })
        await handlePermissionDecision(input, cwd, client, serverUrl, (status) => {
          output.status = status
        })
      } catch (e) {
        debug("permission.ask error", String(e))
        // fail-open: leave status as ask
      }
    },

    event: async ({ event }) => {
      try {
        // OpenCode events: type + top-level fields and/or .properties
        const type = event?.type || event?.name || ""
        const props = event?.properties || event || {}
        const sessionId = pickSessionId(
          cwd,
          event?.sessionID,
          props.sessionID,
          props.sessionId,
          props.session_id,
          props.info,
          props.session,
          props
        )
        const base = {
          cwd,
          working_directory: cwd,
          title: props.title || props.info?.title || props.session?.title || event?.title,
          summary: props.message || props.error || props.status || props.summary,
          message: props.message || props.error,
        }

        if (type === "session.created") {
          await emit("SessionStart", sessionId, base, props)
        } else if (type === "session.idle") {
          await emit("Stop", sessionId, base, props)
        } else if (type === "session.error") {
          await emit("session.failed", sessionId, base, props)
        } else if (type === "session.updated" || type === "session.status") {
          await emit("session.updated", sessionId, base, props)
        } else if (type === "session.deleted") {
          await emit("session.completed", sessionId, base, props)
        } else if (type === "permission.asked" || type === "permission.updated") {
          // Bus fallback when permission.ask hook is not used / already published.
          const perm = props.id ? props : event
          await handlePermissionDecision(perm, cwd, client, serverUrl, null)
        } else if (type === "permission.replied") {
          // OpenCode TUI uses `response` (once|always|reject); some older
          // shapes used `reply`. Prefer the documented field.
          const response =
            props.response ?? props.reply ?? props.decision ?? null
          await emit(
            "tool.approval_resolved",
            sessionId,
            {
              ...base,
              approved:
                response !== "reject" &&
                response !== "deny" &&
                response !== false,
              reply: response,
              response,
            },
            props
          )
        } else if (type === "file.edited") {
          await emit(
            "PostToolUse",
            sessionId,
            {
              ...base,
              tool_name: "edit",
              tool: "edit",
              file_path: props.file || props.path || props.filePath,
            },
            props
          )
        }
      } catch (e) {
        debug("event error", String(e))
      }
    },

    "tool.execute.before": async (input, output) => {
      try {
        const sessionId = pickSessionId(
          cwd,
          input?.sessionID,
          input?.sessionId,
          input?.session_id,
          input?.callID,
          input
        )
        const payload = toolPayload(input, output, cwd)
        await emit("PreToolUse", sessionId, payload, { input, args: output?.args })
      } catch {}
    },

    "tool.execute.after": async (input, output) => {
      try {
        const sessionId = pickSessionId(
          cwd,
          input?.sessionID,
          input?.sessionId,
          input?.session_id,
          input?.callID,
          input
        )
        const payload = toolPayload(input, output, cwd)
        if (output && typeof output === "object") {
          if (typeof output.error === "string") {
            payload.status = "error"
            payload.message = output.error
          } else if (output.error) {
            payload.status = "error"
          } else {
            payload.status = "success"
            payload.success = true
          }
        }
        await emit("PostToolUse", sessionId, payload, { input, output })
      } catch {}
    },
  }
}

export default NocturnalBridge
