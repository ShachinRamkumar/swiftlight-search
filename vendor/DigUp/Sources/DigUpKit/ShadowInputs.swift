import Darwin
import Foundation

public struct RebuiltInput: Sendable {
    public let segment: Int64
    public let file: Int64
    public let kind: String
    public let path: String
    public let loc: Int
    public let text: String
    public let contentRev: Data
    public let snapshot: String
    public let readFile: Bool
    public let metadataTitle: Bool
    public let garbled: Bool
}

extension IndexStore {
    private static let inputColumns = """
        SELECT s.file,s.kind,f.path,coalesce(s.loc,0),coalesce(fts.original,fts.body),
            json_array(s.file,s.kind,s.modality,s.loc,s.loc_end,s.excerpt,hex(s.vec),
                f.path,f.kind,f.size,f.mtime,f.inode,f.device,fts.body,fts.original),
            f.size,f.mtime,f.inode,f.device,fts.original
        FROM segments s JOIN files f ON f.id=s.file LEFT JOIN fts ON fts.rowid=s.id
        WHERE s.id=? AND s.modality='text'
        """

    public func eligibleShadowSegments(model: Int64? = nil, modalities: Set<String> = ["text"]) throws -> [Int64] {
        guard !modalities.isEmpty, modalities.isSubset(of:["text","image","audio","video"]) else { throw WorkerError.failed("invalid shadow modalities") }
        let modalitySQL=modalities.sorted().map { "'"+$0+"'" }.joined(separator:",")
        var ids: [Int64]=[]
        let absent = model.map { " AND NOT EXISTS(SELECT 1 FROM vectors v JOIN embedding_inputs i ON i.segment=v.segment WHERE v.segment=s.id AND v.model=\($0) AND v.content_rev=i.content_rev)" } ?? ""
        try db.query("SELECT s.id FROM segments s WHERE s.modality IN (\(modalitySQL))\(absent) ORDER BY s.file,s.id") { ids.append($0.int(0)) }
        return ids
    }

    public func rebuildInput(segment: Int64, scratch: URL) throws -> RebuiltInput {
        var fields: (file: Int64,kind: String,path: String,loc: Int,body: String?,snapshot: String,original: String?)?
        try db.query(Self.inputColumns,[.int(segment)]) { row in
            fields=(row.int(0),row.text(1)!,row.text(2)!,Int(row.double(3)),row.text(4),row.text(5)!,row.text(10))
        }
        guard let f=fields else { throw WorkerError.failed("segment no longer eligible: \(segment)") }
        // New writes retain the exact input, including titles and bytes before keyword normalization.
        var retained: String?
        try db.query("SELECT input FROM embedding_inputs WHERE segment=?",[.int(segment)]) { retained=$0.text(0) }
        var metadataTitle=false,garbled=false,readFile=false
        let input: String
        if let retained { input=retained }
        else {
            let url=URL(fileURLWithPath:f.path)
            let fallback=url.deletingPathExtension().lastPathComponent
            switch f.kind {
            case "chunk":
                let body: String
                if let original=f.original { body=original }
                else {
                    guard try fileMatches(segment:segment) else { throw WorkerError.failed("changed: \(f.path)") }
                    readFile=true
                    // keywordText used Swift's canonical-equivalence comparison. A NULL
                    // original can therefore hide byte changes such as U+2126 -> U+03A9.
                    if shadowChunks?.file != f.file {
                        shadowChunks=(f.file,try DocExtractor.chunks(DocExtractor.text(of:url),limit:IndexOptions().maxChunks+1))
                    }
                    guard let chunks=shadowChunks?.chunks, chunks.indices.contains(f.loc-1) else {
                        throw WorkerError.failed("cannot recover chunk: \(segment)")
                    }
                    body=chunks[f.loc-1]
                    guard try fileMatches(segment:segment) else { throw WorkerError.failed("changed during extraction: \(f.path)") }
                }
                input=Prompts.document(title:fallback,text:body)
            case "page":
                guard try fileMatches(segment:segment) else { throw WorkerError.failed("changed: \(f.path)") }
                readFile=true
                try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
                let needsText=f.original == nil
                let read=try PDFExtractor.pages(of:url,range:{ _ in needsText ? (f.loc-1)..<f.loc : 0..<0 },minText:200,renderPixels:1400,to:scratch)
                metadataTitle=read.title != nil
                let body: String
                if let original=f.original { body=original }
                else {
                    guard let page=read.pages.first else { throw WorkerError.failed("cannot recover page: \(segment)") }
                    body=page.garbled ?? page.text;garbled=page.garbled != nil
                }
                guard try fileMatches(segment:segment) else { throw WorkerError.failed("changed during extraction: \(f.path)") }
                input=Prompts.document(title:read.title ?? fallback,text:String(body.prefix(4000)))
            default: throw WorkerError.failed("unsupported legacy text segment kind: \(f.kind)")
            }
        }
        let result=RebuiltInput(segment:segment,file:f.file,kind:f.kind,path:f.path,loc:f.loc,text:input,
            contentRev:Self.contentRevision(input),snapshot:f.snapshot,readFile:readFile,
            metadataTitle:metadataTitle,garbled:garbled)
        try db.transaction {
            guard try inputIsCurrent(result) else { throw WorkerError.failed("changed while rebuilding input: \(segment)") }
            try db.run("INSERT INTO embedding_inputs(segment,input,content_rev) VALUES(?,?,?) ON CONFLICT(segment) DO NOTHING",
                       [.int(segment),.text(input),.blob(result.contentRev)])
            guard try storedRevision(segment)==result.contentRev else { throw WorkerError.failed("input revision raced: \(segment)") }
        }
        return result
    }

    func inputIsCurrent(_ input: RebuiltInput) throws -> Bool {
        var snapshot: String?
        try db.query(Self.inputColumns,[.int(input.segment)]) { snapshot=$0.text(5) }
        guard snapshot==input.snapshot else { return false }
        return try !input.readFile || fileMatches(segment:input.segment)
    }

    private func fileMatches(segment: Int64) throws -> Bool {
        var matches=false
        try db.query(Self.inputColumns,[.int(segment)]) { row in
            var st=Darwin.stat()
            guard stat(row.text(2)!,&st)==0 else { return }
            let mtime=Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9
            // Match the persisted size, mtime and inode. Device numbers can change
            // across mounts without changing the file or its model input.
            matches=st.st_size==row.int(6) && mtime==row.double(7)
                && UInt64(st.st_ino)==UInt64(bitPattern:row.int(8))
        }
        return matches
    }
}
