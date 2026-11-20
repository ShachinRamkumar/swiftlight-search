import Foundation

/// The source connection is read only and pinned to one snapshot for the pass.
public final class ShadowCarrySource {
    private let source: Database
    private let sourceModel: Int64

    public init(index: URL, target: IndexStore, model: Int64) throws {
        source = try Database(path: index.appendingPathComponent(target.file.lastPathComponent).path, readOnly: true)
        try source.execute("BEGIN")
        var identity: [String] = []
        let columns = "key,model,weights_sha256,build,prompts,preprocessing,dim,storage"
        try target.db.query("SELECT \(columns) FROM embedding_models WHERE id=?", [.int(model)]) { row in
            identity = (0..<8).map { row.text(Int32($0)) ?? "" }
        }
        var found: Int64?
        try source.query("SELECT id,\(columns) FROM embedding_models WHERE key=? AND state IN ('complete','active','retired')", [.text(identity[0])]) { row in
            guard (1...8).map({ row.text(Int32($0)) ?? "" }) == identity else {
                throw WorkerError.failed("carry source model identity mismatch")
            }
            found = row.int(0)
        }
        guard let found else { throw WorkerError.failed("carry source has no complete matching model") }
        sourceModel = found
        var expected: [String: String] = [:], actual: [String: String] = [:]
        try target.db.query("SELECT modality,identity FROM embedding_modality_identities WHERE model=?", [.int(model)]) { expected[$0.text(0)!] = $0.text(1)! }
        try source.query("SELECT modality,identity FROM embedding_modality_identities WHERE model=?", [.int(found)]) { actual[$0.text(0)!] = $0.text(1)! }
        guard expected.allSatisfy({ actual[$0.key] == $0.value }) else { throw WorkerError.failed("carry source modality identity mismatch") }
    }

    public func vector(target: IndexStore, segment: Int64, revision: Data) throws -> [Float]? {
        var identity: String?, path: String?
        let expression = "json_array(f.path,f.kind,s.kind,s.modality,s.loc,s.loc_end,s.excerpt)"
        try target.db.query("SELECT \(expression),f.path FROM segments s JOIN files f ON f.id=s.file WHERE s.id=?", [.int(segment)]) { identity = $0.text(0); path = $0.text(1) }
        guard let identity, let path else { return nil }
        var data: Data?
        try source.query("""
            SELECT v.vec FROM vectors v JOIN segments s ON s.id=v.segment JOIN files f ON f.id=s.file
            JOIN embedding_inputs i ON i.segment=s.id AND i.content_rev=v.content_rev
            WHERE v.model=? AND v.content_rev=? AND v.modality=s.modality AND f.path=? AND \(expression)=?
            """, [.int(sourceModel), .blob(revision), .text(path), .text(identity)]) { row in
                let next = row.blob(0)!
                guard data == nil || data == next else { throw WorkerError.failed("ambiguous carry source vectors") }
                data = next
            }
        guard let data else { return nil }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 2).map { Float(Float16(bitPattern: bytes.loadUnaligned(fromByteOffset: $0, as: UInt16.self))) }
        }
    }
}
