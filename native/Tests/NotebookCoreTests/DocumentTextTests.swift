import XCTest
@testable import NotebookCore

final class DocumentTextTests: XCTestCase {
    let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixture(_ name: String) throws -> Data { try Data(contentsOf:repo.appendingPathComponent("tests/fixtures/" + name)) }

    func testPDFWordAndImageFilesYieldSearchableTextAndPreviews() throws {
        let pdf = DocumentText.extract(name:"receipt.pdf",type:nil,data:try fixture("receipt.pdf"))
        XCTAssertEqual(pdf["status"] as? String,"ready"); XCTAssertEqual(pdf["method"] as? String,"pdf"); XCTAssertEqual(pdf["pages"] as? Int,1)
        XCTAssertTrue((pdf["text"] as! String).contains("Amount paid: 2450.00 USD"))
        XCTAssertTrue((pdf["preview"] as! String).hasPrefix("data:image/jpeg;base64,"))
        XCTAssertLessThan((pdf["thumb"] as! String).count,(pdf["preview"] as! String).count)
        let docx = DocumentText.extract(name:"memo.docx",type:"application/octet-stream",data:try fixture("memo.docx"))
        XCTAssertEqual(docx["method"] as? String,"office"); XCTAssertTrue((docx["text"] as! String).contains("Tenant: Notebook Tester"))
        XCTAssertEqual(docx["type"] as? String,"application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        let image = DocumentText.extract(name:"invoice.png",type:"image/png",data:try fixture("invoice.png"))
        XCTAssertEqual(image["method"] as? String,"ocr"); XCTAssertTrue((image["text"] as! String).contains("Invoice 4471"),image["text"] as! String)
        XCTAssertTrue((image["text"] as! String).contains("318.40"))
        XCTAssertNotNil(image["thumb"])
    }
    func testTextHTMLUnsupportedAndBrokenFilesReportTheirStatus() {
        let html = DocumentText.extract(name:"page.html",type:nil,data:Data("<title>T</title><script>alert(1)</script><p>Hello &amp; welcome</p><p>Second</p>".utf8))
        XCTAssertEqual(html["text"] as? String,"T Hello & welcome\nSecond"); XCTAssertEqual(html["status"] as? String,"ready")
        let csv = DocumentText.extract(name:"data.csv",type:"text/csv",data:Data("a,b\n1,2".utf8))
        XCTAssertEqual(csv["type"] as? String,"text/csv"); XCTAssertEqual(csv["text"] as? String,"a,b\n1,2")
        let unknown = DocumentText.extract(name:"archive.zip",type:"application/zip",data:Data([0x50,0x4b,0x03,0x04]))
        XCTAssertEqual(unknown["status"] as? String,"unsupported"); XCTAssertEqual(unknown["text"] as? String,"")
        let broken = DocumentText.extract(name:"broken.pdf",type:nil,data:Data("not a pdf".utf8))
        XCTAssertEqual(broken["status"] as? String,"failed"); XCTAssertTrue((broken["message"] as! String).contains("PDF"))
        XCTAssertEqual(DocumentText.mimeType(name:"photo.HEIC"),"image/heic")
        XCTAssertEqual(DocumentText.mimeType(name:"noext",declared:"text/markdown; charset=utf-8"),"text/markdown")
        XCTAssertEqual(DocumentText.mimeType(name:"noext",declared:"application/octet-stream"),"application/octet-stream")
    }
    func testSpreadsheetsResolveSharedStringsAcrossSheets() throws {
        let workbook = "<workbook><sheets><sheet name=\"Budget\" sheetId=\"1\"/><sheet name=\"Notes\" sheetId=\"2\"/></sheets></workbook>"
        let strings = "<sst><si><t>Rent</t></si><si><r><t>Gro</t></r><r><t>ceries</t></r></si></sst>"
        let sheet1 = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\"><v>2450</v></c></row><row r=\"2\"><c r=\"A2\" t=\"s\"><v>1</v></c><c r=\"B2\"><v>412.5</v></c></row></sheetData></worksheet>"
        let sheet2 = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Paid &amp; filed</t></is></c></row></sheetData></worksheet>"
        let zip = Self.zip([("xl/workbook.xml",workbook),("xl/sharedStrings.xml",strings),("xl/worksheets/sheet1.xml",sheet1),("xl/worksheets/sheet2.xml",sheet2)])
        let result = DocumentText.extract(name:"budget.xlsx",type:nil,data:zip)
        XCTAssertEqual(result["status"] as? String,"ready"); XCTAssertEqual(result["pages"] as? Int,2)
        XCTAssertEqual(result["text"] as? String,"[Budget]\nRent\t2450\nGroceries\t412.5\n\n[Notes]\nPaid & filed")
    }
    func testStoreKeepsDocumentsAndTheirBytesAsSeparateSyncedRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try RecordStore(url:directory.appendingPathComponent("documents.sqlite"))
        _ = try store.setKey("app_documents",value:["documents":[["id":"doc","name":"receipt.pdf","type":"application/pdf","text":"Amount paid","textStatus":"ready","modifiedAt":"2026-10-15T12:00:00Z"]]])
        _ = try store.setKey("app_documentData_doc",value:["type":"application/pdf","data":"data:application/pdf;base64,JVBERi0=","preview":"data:image/jpeg;base64,cHJldmlldw==","thumb":"data:image/jpeg;base64,dGh1bWI="])
        let documents = try XCTUnwrap((try store.getKey("app_documents") as? [String:Any])?["documents"] as? [[String:Any]])
        XCTAssertEqual(documents.count,1); XCTAssertEqual(documents[0]["text"] as? String,"Amount paid")
        XCTAssertEqual((try store.getKey("app_documentData_doc") as? [String:Any])?["data"] as? String,"data:application/pdf;base64,JVBERi0=")
        XCTAssertEqual(try store.documentPreviews(["doc","missing"]),["doc":"data:image/jpeg;base64,dGh1bWI="])
        XCTAssertEqual(try store.documentPreviews(["doc"],field:"preview"),["doc":"data:image/jpeg;base64,cHJldmlldw=="])
        XCTAssertThrowsError(try store.documentPreviews(["doc"],field:"data"))
        XCTAssertEqual(Set(try store.revisions().map(\.kind)),["documents","documentData"])
        XCTAssertTrue(try store.keys().contains("app_documentData_doc"))
        // Another device receives both revisions and reads the same records.
        let phone = try RecordStore(url:directory.appendingPathComponent("phone.sqlite"))
        try phone.receive(try store.revisions())
        XCTAssertEqual(((try phone.getKey("app_documents") as? [String:Any])?["documents"] as? [[String:Any]])?.first?["name"] as? String,"receipt.pdf")
        try store.deleteKey("app_documentData_doc")
        _ = try store.setKey("app_documents",value:["documents":[],"_syncDeleted":documents])
        XCTAssertNil(try store.getKey("app_documentData_doc"))
        XCTAssertEqual(((try store.getKey("app_documents") as? [String:Any])?["documents"] as? [[String:Any]])?.count,0)
        XCTAssertEqual(try store.documentPreviews(["doc"]),[:])
    }
    /// A zip with stored (uncompressed) entries, enough for the Office reader.
    static func zip(_ files: [(String,String)]) -> Data {
        var output = Data(), central = Data(), offsets: [Int] = []
        func put16(_ data: inout Data, _ value: Int) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8 & 0xff)) }
        func put32(_ data: inout Data, _ value: Int) { put16(&data,value & 0xffff); put16(&data,value >> 16 & 0xffff) }
        for (name, text) in files {
            let body = Data(text.utf8), nameBytes = Data(name.utf8)
            offsets.append(output.count)
            output.append(contentsOf:[0x50,0x4b,0x03,0x04])
            put16(&output,20); put16(&output,0); put16(&output,0); put16(&output,0); put16(&output,0)
            put32(&output,0); put32(&output,body.count); put32(&output,body.count)
            put16(&output,nameBytes.count); put16(&output,0)
            output.append(nameBytes); output.append(body)
        }
        for (index, (name, text)) in files.enumerated() {
            let body = Data(text.utf8), nameBytes = Data(name.utf8)
            central.append(contentsOf:[0x50,0x4b,0x01,0x02])
            put16(&central,20); put16(&central,20); put16(&central,0); put16(&central,0); put16(&central,0); put16(&central,0)
            put32(&central,0); put32(&central,body.count); put32(&central,body.count)
            put16(&central,nameBytes.count); put16(&central,0); put16(&central,0); put16(&central,0); put16(&central,0)
            put32(&central,0); put32(&central,offsets[index])
            central.append(nameBytes)
        }
        let start = output.count
        output.append(central)
        output.append(contentsOf:[0x50,0x4b,0x05,0x06])
        put16(&output,0); put16(&output,0); put16(&output,files.count); put16(&output,files.count)
        put32(&output,central.count); put32(&output,start); put16(&output,0)
        return output
    }
}
