import Darwin
import DigUpKit
import Foundation

@available(macOS 27, *)
enum SpecializationAudit {
    static func fromEnvironment(cacheRoots: [String] = [NSHomeDirectory()+"/Library/Caches/coreai-cache", NSHomeDirectory()+"/Library/Application Support/coreai-cache"]) -> (@Sendable (URL, SpecializationPhase) throws -> Void)? {
        guard let path=ProcessInfo.processInfo.environment["P3B_SPECIALIZATION_AUDIT_DIR"] else { return nil }
        return { url,phase in try record(url,phase:phase,directory:URL(fileURLWithPath:path), cacheRoots:cacheRoots) }
    }

    private static func record(_ url: URL, phase: SpecializationPhase, directory: URL, cacheRoots: [String]) throws {
        let functions: Set<String> = ["q32","q64","q128","d256","d512","d1024","d2048","v630","v1260","v2520","a3000","query-rest","vision-rest"]
        let single = url.deletingLastPathComponent().lastPathComponent == "function-assets"
            && url.pathExtension == "aimodel" && functions.contains(url.deletingPathExtension().lastPathComponent)
        guard ["EmbeddingGemma2.aimodel","text.aimodel","text-query.aimodel","text-doc.aimodel","vision.aimodel","audio.aimodel"].contains(url.lastPathComponent) || single else {
            throw WorkerError.failed("unexpected specialization asset: \(url.path)")
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fd=open(directory.appendingPathComponent("budget.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else { throw WorkerError.failed("cannot open specialization budget") }
        defer { Darwin.close(fd) }
        guard flock(fd,LOCK_EX)==0 else { throw WorkerError.failed("cannot lock specialization budget") }
        defer { _=flock(fd,LOCK_UN) }
        let budgetURL=directory.appendingPathComponent("counts.json")
        var counts=(try? JSONDecoder().decode([String:Int].self,from:Data(contentsOf:budgetURL))) ?? [:]
        let free=(try FileManager.default.attributesOfFileSystem(forPath:directory.path)[.systemFreeSize] as! NSNumber).int64Value
        var sizes: [String:String]=[:]
        for path in cacheRoots {
            let process=Process(),pipe=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/du");process.arguments=["-sk",path];process.standardOutput=pipe
            try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0 else { throw WorkerError.failed("cache measurement failed") }
            sizes[path]=String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        if phase == .begin {
            guard free>=9_000_000_000,counts[url.lastPathComponent,default:0]<min(3,Int(ProcessInfo.processInfo.environment["P3B_SPECIALIZATION_LIMIT"] ?? "2") ?? 2) else {
                throw WorkerError.failed("specialization budget or disk headroom exhausted")
            }
            counts[url.lastPathComponent,default:0]+=1
            try JSONEncoder().encode(counts).write(to:budgetURL,options:.atomic)
        }
        let record: [String:Any]=["phase":String(describing:phase),"url":url.path,"pid":getpid(),"time":Date().timeIntervalSince1970,
                                  "cache_du_kib":sizes,"disk_free_bytes":free,"counts":counts]
        let file=directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath:file.path) { FileManager.default.createFile(atPath:file.path,contents:nil) }
        let handle=try FileHandle(forWritingTo:file);defer { try? handle.close() }
        try handle.seekToEnd();try handle.write(contentsOf:JSONSerialization.data(withJSONObject:record)+Data([10]))
    }
}
