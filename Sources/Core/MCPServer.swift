import Foundation

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Read-only: it lists and reads meetings; it never records, deletes or sends anything.
public final class MCPServer {
    public static let version = "0.1.7"
    let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public init() {}

    public static let tools: [[String: Any]] = [
        tool("list_meetings", "List recorded meetings, newest first: id, title, date, duration, speakers, number of action items.",
             ["limit": ["type": "integer", "description": "Max meetings to return (default 20)"]], []),
        tool("get_transcript", "Full speaker-labelled transcript of one meeting as Markdown.",
             ["meeting_id": ["type": "string", "description": "Meeting id from list_meetings, or \"latest\""]], ["meeting_id"]),
        tool("get_summary", "Summary, decisions, action items and open questions of one meeting as Markdown.",
             ["meeting_id": ["type": "string", "description": "Meeting id from list_meetings, or \"latest\""]], ["meeting_id"]),
        tool("get_action_items", "Action items (owner, task, due) as JSON. Omit meeting_id to get items from all meetings.",
             ["meeting_id": ["type": "string", "description": "Optional meeting id or \"latest\""]], []),
        tool("search", "Search all meetings (titles, transcripts, summaries, action items) for a word or phrase.",
             ["query": ["type": "string"], "limit": ["type": "integer", "description": "Max hits per meeting (default 10)"]], ["query"]),
    ]

    static func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    /// Blocking loop: one JSON message per line on stdin, replies on stdout.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let reply = handle(Data(line)) {
                    output.write(reply); output.write(Data([0x0A]))
                }
            }
        }
    }

    /// Handles one raw message; returns the reply bytes, or nil for notifications.
    public func handle(_ raw: Data) -> Data? {
        guard !raw.isEmpty else { return nil }
        guard let msg = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        if id == nil { return nil }   // notification (e.g. notifications/initialized)
        do {
            let result = try dispatch(method, params)
            return encode(["jsonrpc": "2.0", "id": id!, "result": result])
        } catch let e as RPCError {
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": e.code, "message": e.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "\(error)"]])
        }
    }

    struct RPCError: Error { var code: Int; var message: String }

    func dispatch(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = p["protocolVersion"] as? String ?? ""
            return ["protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "hush", "version": Self.version],
                    "instructions": "Read-only access to meetings recorded locally by Hush. Use list_meetings first, then get_summary or get_transcript."]
        case "ping": return [:]
        case "tools/list": return ["tools": Self.tools]
        case "tools/call":
            let name = p["name"] as? String ?? ""
            let args = p["arguments"] as? [String: Any] ?? [:]
            do { return ["content": [["type": "text", "text": try call(name, args)]], "isError": false] }
            catch let e as RPCError { throw e }
            catch { return ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true] }
        default: throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    func meeting(_ args: [String: Any]) throws -> Meeting {
        let id = (args["meeting_id"] as? String) ?? "latest"
        if id == "latest" {
            guard let m = Store.all().first else { throw HushError.missing("no meetings recorded yet") }
            return m
        }
        do { return try Store.load(id) } catch { throw HushError.missing("meeting \(id)") }
    }

    public func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_meetings":
            let limit = (args["limit"] as? Int) ?? 20
            let f = ISO8601DateFormatter()
            let list: [[String: Any]] = Store.all().prefix(limit).map { m in
                ["id": m.id, "title": m.title, "date": f.string(from: m.createdAt), "duration": formatTime(m.duration),
                 "status": m.status.rawValue, "speakers": m.speakers.map(m.displayName),
                 "action_items": m.summary?.actionItems.count ?? 0]
            }
            return json(list)
        case "get_transcript":
            let m = try meeting(args)
            return m.segments.isEmpty ? "Meeting \(m.id) has no transcript yet (status: \(m.status.rawValue))." : Markdown.transcript(m)
        case "get_summary":
            let m = try meeting(args)
            return m.summary == nil ? "Meeting \(m.id) has no summary yet. Run: hush summarize \(m.id)" : Markdown.summary(m)
        case "get_action_items":
            let ms = args["meeting_id"] == nil ? Store.all() : [try meeting(args)]
            let items: [[String: Any]] = ms.flatMap { m in
                (m.summary?.actionItems ?? []).map { a in
                    ["meeting_id": m.id, "meeting": m.title, "owner": a.owner ?? NSNull(), "task": a.task, "due": a.due ?? NSNull(), "done": a.done]
                }
            }
            return json(items)
        case "search":
            guard let q = args["query"] as? String, !q.isEmpty else { throw RPCError(code: -32602, message: "query is required") }
            let limit = (args["limit"] as? Int) ?? 10
            let res: [[String: Any]] = Store.search(q).map { ["meeting_id": $0.meeting.id, "title": $0.meeting.title, "hits": Array($0.hits.prefix(limit))] }
            return res.isEmpty ? "No matches for \"\(q)\"." : json(res)
        default:
            throw RPCError(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    func encode(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }
}
