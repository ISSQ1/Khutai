import Foundation

enum CodexPlannerError: LocalizedError {
    case unavailable
    case execution(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "لم يُعثر على Codex على الجهاز. يلزم فتح تطبيق Codex وتسجيل الدخول بحساب ChatGPT."
        case .execution(let message):
            message
        case .invalidResponse:
            "وصلت خطة غير مكتملة من Codex. يرجى المحاولة مرة أخرى."
        }
    }
}

struct CodexPlanner {
    static var isAvailable: Bool { executableURL != nil }

    func createPlan(tasks: [PlannerTask], date: Date) async throws -> DailyPlan {
        guard let executableURL = Self.executableURL else {
            throw CodexPlannerError.unavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            try runCodex(executableURL: executableURL, tasks: tasks, date: date)
        }.value
    }

    private static var executableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

private func runCodex(executableURL: URL, tasks: [PlannerTask], date: Date) throws -> DailyPlan {
    let files = try prepareWorkspace()
    defer { try? FileManager.default.removeItem(at: files.workspace) }
    let prompt = try planningPrompt(tasks: tasks, date: date)
    try executeCodex(executableURL: executableURL, files: files, prompt: prompt)
    return try decodePlan(at: files.output, generatedAt: date)
}

private struct CodexRunFiles {
    let workspace: URL
    let schema: URL
    let output: URL
    let error: URL
}

private func prepareWorkspace() throws -> CodexRunFiles {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("lotus-planner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let schemaURL = workspace.appendingPathComponent("daily-plan-schema.json")
    let outputURL = workspace.appendingPathComponent("daily-plan.json")
    let errorURL = workspace.appendingPathComponent("codex-error.txt")
    try JSONSerialization.data(withJSONObject: makePlanSchema()).write(to: schemaURL)
    _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    return CodexRunFiles(workspace: workspace, schema: schemaURL, output: outputURL, error: errorURL)
}

private func executeCodex(executableURL: URL, files: CodexRunFiles, prompt: String) throws {
    let process = Process()
    process.executableURL = executableURL
    process.currentDirectoryURL = files.workspace
    process.arguments = codexArguments(schemaURL: files.schema, outputURL: files.output, workspace: files.workspace)

    let inputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = FileHandle.nullDevice
    let errorHandle = try FileHandle(forWritingTo: files.error)
    defer { try? errorHandle.close() }
    process.standardError = errorHandle

    try process.run()
    inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
    try inputPipe.fileHandleForWriting.close()
    try waitForCodex(process)

    guard process.terminationStatus == 0 else {
        let errorText = (try? String(contentsOf: files.error, encoding: .utf8)) ?? ""
        throw CodexPlannerError.execution(readableCodexError(errorText))
    }
}

private func waitForCodex(_ process: Process) throws {
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    guard completion.wait(timeout: .now() + 120) == .success else {
        process.terminate()
        throw CodexPlannerError.execution("استغرق التخطيط وقتًا طويلًا. يرجى المحاولة مرة أخرى.")
    }
}

private func decodePlan(at outputURL: URL, generatedAt: Date) throws -> DailyPlan {
    guard let planData = try? Data(contentsOf: outputURL),
          let payload = try? JSONDecoder().decode(PlanPayload.self, from: planData) else {
        throw CodexPlannerError.invalidResponse
    }
    return DailyPlan(
        date: payload.date,
        overview: payload.overview,
        schedule: payload.schedule,
        encouragement: payload.encouragement,
        generatedAt: generatedAt
    )
}

private func codexArguments(schemaURL: URL, outputURL: URL, workspace: URL) -> [String] {
    [
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
        "--sandbox", "read-only",
        "--model", "gpt-5.6-luna",
        "--cd", workspace.path,
        "--output-schema", schemaURL.path,
        "--output-last-message", outputURL.path,
        "-"
    ]
}

private func planningPrompt(tasks: [PlannerTask], date: Date) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let taskJSON = String(decoding: try encoder.encode(tasks), as: UTF8.self)
    let currentDate = PlannerStorage.dateKey(for: date)
    return """
    أنت مخطط حياة عربي حنون وعملي. خاطب القارئ بصيغة محايدة لا تكشف عن جنسه: استخدم المصدر والجمل الاسمية، وتجنّب صيغ المذكر والمؤنث في الأفعال والضمائر. لا تستخدم أي أدوات ولا تقرأ أي ملفات؛ أعد الخطة النهائية فقط.
    ابدأ من التاريخ \(currentDate) وخطط حتى آخر موعد نهائي موجود.
    فكك كل هدف كبير إلى خطوات عملية واضحة ومحددة، ووزعها على الأيام السابقة لموعده حتى لا يتكدس العمل في يوم التسليم.
    استخدم notes لفهم المتطلبات والترتيب المنطقي بينها. قدّر بنفسك المدة الواقعية لكل خطوة بالدقائق وضعها في estimatedMinutes؛ لا تعتمد على durationMinutes لأنه حقل قديم.
    لا تتجاوز خطوات الدوام خمس ساعات عمل فعلية في اليوم، ووزّع ما زاد على الأيام السابقة للموعد النهائي. لا تحدد ساعة بدء أو انتهاء.
    قد تُنجز مهام الدوام في المنزل، لذلك نظّمها بحسب اليوم لا المكان أو الساعة. يوم الديدلاين اجعل الخطوة الأخيرة للتسليم أو المراجعة النهائية.
    استخدم التقويم الميلادي فقط. اجعل taskID مساويًا لقيمة id للمهمة الأم، وscheduledDate بصيغة yyyy-MM-dd، وcategory إما work أو personal.
    اختم بتشجيع عربي قوي وحنون وقصير، بصيغة محايدة أيضًا.

    المهام بصيغة JSON:
    \(taskJSON)
    """
}

private func readableCodexError(_ errorText: String) -> String {
    if errorText.localizedCaseInsensitiveContains("login") {
        return "يحتاج Codex إلى تسجيل الدخول بحساب ChatGPT أولًا."
    }
    if errorText.localizedCaseInsensitiveContains("usage limit") {
        return "وصل اشتراكك إلى حد الاستخدام الحالي. يرجى المحاولة لاحقًا."
    }
    return "تعذر تشغيل المخطط الآن. يلزم فتح Codex ثم المحاولة مرة أخرى."
}

private func makePlanSchema() -> [String: Any] {
    [
        "type": "object",
        "additionalProperties": false,
        "required": ["date", "overview", "schedule", "encouragement"],
        "properties": [
            "date": ["type": "string"],
            "overview": ["type": "string"],
            "schedule": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["taskID", "title", "scheduledDate", "category", "note", "estimatedMinutes"],
                    "properties": [
                        "taskID": ["type": "string"],
                        "title": ["type": "string"],
                        "scheduledDate": ["type": "string"],
                        "category": ["type": "string", "enum": ["work", "personal"]],
                        "note": ["type": "string"],
                        "estimatedMinutes": ["type": "integer", "minimum": 5, "maximum": 300]
                    ]
                ]
            ],
            "encouragement": ["type": "string"]
        ]
    ]
}

private struct PlanPayload: Decodable {
    let date: String
    let overview: String
    let schedule: [PlannedTask]
    let encouragement: String
}
