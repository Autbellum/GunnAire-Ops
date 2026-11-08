"""Compile the supplied native consumer's actual recovery decoder against synthetic HTTP output.

Run explicitly, outside backend test discovery. Requires macOS Swift/CryptoKit and
localhost fixture permission. No app build, real account, network service or keys.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Backend import test_document_content_proof as fixtures


SUPPORT = r'''
import Foundation
import CryptoKit
struct SharedCompanyDocumentUploadRequest: Decodable {
    let operationID: UUID
    let data: Data
    let filename, contentType, kind: String
    let serviceCallID, invoiceID, estimateID, maintenanceContractID, customerEquipmentID: UUID?
    let customerName: String?
}
struct BackendDocumentUploadResponse {
    let id, filename: String
    let storedPath, createdAt: String?
}
enum CompanyDocumentContentError: Error { case invalid, changed }
enum QBODocumentFileInfo {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
enum Consumer {
'''

HARNESS = r'''
}
let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
let request = try JSONDecoder().decode(SharedCompanyDocumentUploadRequest.self, from: encode(fixture["request"]!))
let absent = try Consumer.verifiedDocumentUploadRecovery(encode(fixture["absent"]!), request: request)
precondition(absent == nil)
let found = fixture["found"] as! [String: Any]
let result = try Consumer.verifiedDocumentUploadRecovery(encode(found), request: request, equipmentName: "  ")
precondition(result?.id == fixture["expectedID"] as? String)
func rejects(_ object: [String: Any]) {
    do {
        _ = try Consumer.verifiedDocumentUploadRecovery(encode(object), request: request)
        fatalError("Native consumer accepted a mismatched recovery")
    } catch {}
}
var wrongSchema = found; wrongSchema["schema"] = "unrecognized"; rejects(wrongSchema)
var missingDocument = found; missingDocument.removeValue(forKey: "document"); rejects(missingDocument)
var wrongOperation = found; wrongOperation["operationID"] = UUID().uuidString.lowercased(); rejects(wrongOperation)
var wrongDigest = found; var document = found["document"] as! [String: Any]
document["fileSHA256"] = String(repeating: "0", count: 64); wrongDigest["document"] = document; rejects(wrongDigest)
var wrongMetadata = found; document = found["document"] as! [String: Any]
document["filename"] = "different.pdf"; wrongMetadata["document"] = document; rejects(wrongMetadata)
print("7 native recovery wire checks passed")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-source', type=Path, required=True)
    args = parser.parse_args()
    raw = args.native_source.read_bytes()
    source = raw.decode()
    start = source.index('    nonisolated struct DocumentUploadRecovery:')
    end = source.index('    /// Validate a background caller', start)
    # Copy verbatim production decoder, normalization and verification functions.
    extracted = source[start:end]
    test = fixtures.DocumentContentProofHTTPTests()
    test.setUp()
    try:
        operation = str(uuid.uuid4())
        path = '/api/document-uploads/' + operation
        status, absent = test.f.request(token=test.f.tokens['Admin'], path=path)
        assert status == 200
        status, created = test.upload(operationID=operation, filename=' José.pdf ', equipmentName='  ', customerName='Synthetic Customer')
        assert status == 201
        status, found = test.f.request(token=test.f.tokens['Admin'], path=path)
        assert status == 200
        fixture = {'request': {'operationID': operation, 'data': base64.b64encode(b'original-file').decode(),
                   'filename': ' José.pdf ', 'contentType': 'application/pdf', 'kind': 'service_report',
                   'customerName': 'Synthetic Customer'}, 'absent': absent, 'found': found, 'expectedID': created['id']}
        with tempfile.TemporaryDirectory(prefix='gunnaire-wire-contract-') as folder:
            root = Path(folder)
            (root / 'contract.swift').write_text(SUPPORT + extracted + HARNESS)
            (root / 'fixture.json').write_text(json.dumps(fixture))
            subprocess.run(['swiftc', '-module-cache-path', str(root / 'module-cache'), str(root / 'contract.swift'), '-o', str(root / 'check')], check=True)
            subprocess.run([str(root / 'check'), str(root / 'fixture.json')], check=True)
        print(json.dumps({'nativeSourceSHA256': hashlib.sha256(raw).hexdigest(),
                          'extractedDecoderSHA256': hashlib.sha256(extracted.encode()).hexdigest(),
                          'scope': 'Actual decoder with lightweight dependent model/hash types; not an app build or device run.'}))
    finally:
        test.doCleanups()


if __name__ == '__main__':
    main()
