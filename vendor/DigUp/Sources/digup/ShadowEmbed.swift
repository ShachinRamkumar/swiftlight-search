import DigUpCoreAIRuntime
import DigUpKit
import Foundation

func shadowSelection(_ args: Arguments) throws -> Set<Int64>? {
    guard let file=args.values["--only-segments"] else { return nil }
    let text=try String(contentsOfFile:file,encoding:.utf8)
    let words=text.split(whereSeparator:{ $0.isWhitespace || $0 == "," })
    let ids=try words.map { word in
        guard let id=Int64(word), id>0 else { throw CLIError("invalid segment ID: \(word)") }
        return id
    }
    return Set(ids)
}

func shadowInputs(_ args: Arguments) throws {
    guard args.values["--index"] != nil, let output=args.values["--output"] else {
        throw CLIError("shadow-inputs needs explicit --index DIR and --output FILE")
    }
    let store=try args.store(), selected=try shadowSelection(args)
    let scratch=args.indexFolder.appendingPathComponent("input-scratch-\(getpid())")
    defer { try? FileManager.default.removeItem(at:scratch) }
    var inputs: [[String:Any]]=[]
    for segment in try store.eligibleShadowSegments() where selected?.contains(segment) ?? true {
        if let limit=args.values["--limit"].flatMap(Int.init), inputs.count>=limit { break }
        do {
            let input=try autoreleasepool { try store.rebuildInput(segment:segment,scratch:scratch) }
            inputs.append(["segment":segment,"file":input.file,"kind":input.kind,"path":input.path,"loc":input.loc,
                "input":input.text,"content_rev":input.contentRev.map { String(format:"%02x",$0) }.joined(),
                "metadata_title":input.metadataTitle,"garbled":input.garbled])
        } catch { inputs.append(["segment":segment,"error":"\(error)"]) }
    }
    let data=try JSONSerialization.data(withJSONObject:inputs,options:[.sortedKeys,.prettyPrinted])
    try data.write(to:URL(fileURLWithPath:output),options:.atomic)
    emit(["event":"inputs","segments":inputs.count,"output":output])
}

func shadowEmbed(_ args: Arguments) throws -> Int32 {
    guard args.values["--index"] != nil, args.values["--runtime"] != nil,
          ["coreai-eg2-text-v1","coreai-eg2-v1"].contains(args.values["--model-key"] ?? "") else {
        throw CLIError("shadow-embed needs --index DIR --runtime DIR --model-key coreai-eg2-text-v1")
    }
    if let raw=args.values["--limit"], Int(raw).map({$0<0}) ?? true { throw CLIError("invalid --limit") }
    let result=WorkerExitStatus(),done=DispatchSemaphore(value:0)
    Thread.detachNewThread {
        defer { done.signal() }
        do {
            guard #available(macOS 27, *) else { throw CLIError("Core AI requires macOS 27") }
            result.status=try runShadowEmbed(args)
        } catch { emit(["event":"error","message":"\(error)","fatal":true]);result.status=1 }
    }
    done.wait()
    return result.status
}
private final class WorkerExitStatus: @unchecked Sendable { var status: Int32=1 }

@available(macOS 27, *)
private func runShadowEmbed(_ args: Arguments) throws -> Int32 {
    let store=try args.store()
    let runtime=try RuntimeDirectory(URL(fileURLWithPath:args.values["--runtime"]!))
    let control=ModelCallControl()
    Thread.detachNewThread {
        while let line=readLine() { control.command(line.trimmingCharacters(in:.whitespaces)) }
        control.command("stop")
    }
    try control.waitForModelCall()
    let embedder=try runtime.embedder(.document, inferenceGate: { try control.waitForModelCall() })
    defer { embedder.close() }
    let model=try store.registerShadow(key:args.values["--model-key"]!,info:embedder.info,weightsSHA256:runtime.weightsSHA256)
    guard args.values["--model-key"] == runtime.modelKey else { throw CLIError("runtime/model-key mismatch") }
    var modalities=Set((args.values["--modalities"] ?? "text").split(separator:",").map(String.init))
    guard runtime.modelKey == "coreai-eg2-v1" || modalities == ["text"] else { throw CLIError("images need coreai-eg2-v1") }
    if runtime.assets.audioRevision == nil { modalities.remove("audio") }
    if modalities.contains("audio") {
        guard let identity=runtime.assets.audioRevision else { throw CLIError("runtime has no audio identity") }
        try store.registerShadowAudio(model:model,identity:identity)
    }
    if modalities.contains("video") {
        guard let identity=runtime.assets.videoRevision else { throw CLIError("runtime has no video identity") }
        try store.registerShadowVideo(model:model,identity:identity)
        try store.ensureVideoClips()
    }
    let carryIndex = args.values["--carry-from"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    let carrySource = try carryIndex.map { try ShadowCarrySource(index: $0, target: store, model: model) }
    if let carry=args.values["--carry-from"], carryIndex == nil {
        guard carry == "coreai-eg2-text-v1" else { throw CLIError("unsupported carry source") }
        let source=try runtime.verifiedTextCarrySource(runtime.directory.deletingLastPathComponent().appendingPathComponent(carry))
        let count=try store.carryShadowText(model:model,from:carry,sourceBuild:source.assets.revision,weights:source.weightsSHA256)
        emit(["event":"carry","from":carry,"to":runtime.modelKey,"rows":count,"text_identity_verified":true])
    }
    let selection=try shadowSelection(args)
    let ids=try store.eligibleShadowSegments(model:model,modalities:modalities).filter { selection?.contains($0) ?? true }
    let limit=args.values["--limit"].flatMap(Int.init) ?? ids.count
    let scratch=args.indexFolder.appendingPathComponent("shadow-scratch-\(getpid())")
    defer { try? FileManager.default.removeItem(at:scratch) }
    let started=Date()
    var processed=0,refused=0
    var carried: [String: Int] = [:]
    func carriedVector(_ segment: Int64, _ revision: Data, _ modality: String) throws -> [Float]? {
        guard let vector = try carrySource?.vector(target: store, segment: segment, revision: revision) else { return nil }
        carried[modality, default: 0] += 1
        return vector
    }
    var coverage=ShadowProgress()
    @discardableResult
    func progress(_ event: String, bucket: Int? = nil) throws -> Int {
        let snapshot=try coverage.snapshot(event:event,processed:processed,now:ProcessInfo.processInfo.systemUptime) {
            try store.shadowCounts(model:model)
        }
        let counts=snapshot.counts
        emit(["event":event,"done":counts.done,"eligible":counts.eligible,"failed":counts.failed,
              "counts_exact":snapshot.exact,"counts_age_s":snapshot.age,
              "processed":processed,"refused":refused,"rate":Double(processed)/max(0.001,Date().timeIntervalSince(started)),
              "last_timings":embedder.lastTimings.last.map { ["model_ms":$0.modelMS,"total_ms":$0.totalMS] as Any } ?? NSNull(),
              "bucket":bucket.map { $0 as Any } ?? NSNull(),"model":args.values["--model-key"]!])
        return counts.failed
    }
    try progress("ready")
    for segment in ids.prefix(limit) {
        if control.isStopped { break }
        do {
            try control.waitForModelCall()
            if try store.segmentModality(segment) == "video" {
                let start=Date(),input=try store.rebuildVideo(segment:segment)
                let rebuilt=Date()
                let vector=try carriedVector(segment, input.contentRev, "video") ?? embedder.embedVideoFrames(input.frames)
                let embedded=Date()
                if try !store.commitShadowVideo(model:model,input:input,vector:vector) { refused+=1 }
                emit(["event":"video_timing","segment":segment,"start":input.range.start,"end":input.range.end,
                    "frames":input.frames.count,"rebuild_ms":rebuilt.timeIntervalSince(start)*1000,
                    "embed_ms":embedded.timeIntervalSince(rebuilt)*1000,"write_ms":Date().timeIntervalSince(embedded)*1000])
            } else if try store.segmentModality(segment) == "image" {
                let input=try autoreleasepool { try store.rebuildImage(segment:segment,scratch:scratch) }
                defer { try? FileManager.default.removeItem(at:input.prepared) }
                try control.waitForModelCall()
                emit(["event":"model_call","segment":segment,"budget":input.budget])
                let vector: [Float]
                if let existing = try carriedVector(segment, input.contentRev, "image") { vector = existing }
                else {
                    let image=try embedder.embedImages([input.prepared.path],budget:input.budget)[0]
                    guard let embedded=image.vector else { throw CLIError(image.error ?? "image embedding failed") }
                    vector = embedded
                }
                if try !store.commitShadowImage(model:model,input:input,vector:vector) { refused+=1 }
            } else if try store.segmentModality(segment) == "audio" {
                let input=try autoreleasepool { try store.rebuildAudio(segment:segment,scratch:scratch) }
                defer { try? FileManager.default.removeItem(at:input.prepared.deletingLastPathComponent()) }
                try control.waitForModelCall()
                emit(["event":"model_call","segment":segment,"modality":"audio"])
                let vector: [Float]
                if let existing = try carriedVector(segment, input.contentRev, "audio") { vector = existing }
                else {
                    let audio=try embedder.embedAudio([input.prepared.path])[0]
                    guard let embedded=audio.vector else { throw CLIError(audio.error ?? "audio embedding failed") }
                    vector = embedded
                }
                let writeStart=Date()
                if try !store.commitShadowAudio(model:model,input:input,vector:vector) { refused+=1 }
                emit(["event":"audio_timing","segment":segment,"write_ms":Date().timeIntervalSince(writeStart)*1000,
                      "timings":try JSONSerialization.jsonObject(with:JSONEncoder().encode(embedder.lastAudioTimings))])
            } else {
                let input=try autoreleasepool { try store.rebuildInput(segment:segment,scratch:scratch) }
                try control.waitForModelCall()
                emit(["event":"model_call","segment":segment])
                let vector=try carriedVector(segment, input.contentRev, "text") ?? embedder.embedTexts([input.text])[0]
                if try !store.commitShadow(model:model,input:input,vector:vector) { refused+=1 }
            }
            processed+=1
            try progress("progress",bucket:embedder.lastTimings.first?.bucket)
        } catch {
            if control.isStopped { break }
            let reason: String
            if case WorkerError.failed(let message) = error,
               message.hasPrefix("source_changed:") || message.hasPrefix("source_changed during ")
                || message.hasPrefix("changed:") || message.hasPrefix("changed during ") {
                reason = "source_changed"
            } else if case WorkerError.failed(let message) = error, message.hasPrefix("source_unreproducible:") {
                reason = "source_unreproducible"
            } else { reason = String(describing: error) }
            try store.recordShadowFailure(model:model,segment:segment,reason:reason)
            emit(["event":"segment_error","segment":segment,"message":"\(error)"])
        }
    }
    let complete=try store.finishShadowIfCovered(model:model)
    let failed=try progress("summary")
    emit(["event":"finished","complete":complete,"stopped":control.isStopped,"carried":carried,
          "embedded":processed-carried.values.reduce(0,+)])
    return failed==0 ? 0 : 1
}
