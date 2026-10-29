import XCTest
import JavaScriptCore
@testable import NotebookCore

final class AgentRuntimeTests: XCTestCase {
    func testMobileJavaScriptCoreRunsTheSharedToolsAndProviderProtocol() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try RecordStore(url:directory.appendingPathComponent("phone.sqlite"))
        let context = JSContext()!
        var exception: String?
        context.exceptionHandler = { _,value in exception = value?.toString() }
        let read: @convention(block) (String) -> String = { key in
            (try? jsonString(["value":store.getKey(key) ?? NSNull()])) ?? "{}"
        }
        let write: @convention(block) (String,String) -> String = { key,text in
            do { return try jsonString(["value":store.setKey(key,value:jsonObject(text))]) }
            catch { return (try? jsonString(["error":error.localizedDescription])) ?? "{}" }
        }
        context.setObject(read,forKeyedSubscript:"agentRead" as NSString)
        context.setObject(write,forKeyedSubscript:"agentWrite" as NSString)
        context.evaluateScript("""
        var window = {}, input = null;
        const AppManager = {register(){}};
        const localStorage = {getItem(){return null;},setItem(){}};
        const UIUtils = {todayISO:()=>new Date().toISOString().slice(0,10)};
        function unwrap(text){const result=JSON.parse(text);if(result.error)throw new Error(result.error);return result.value;}
        const StorageManager={get:key=>unwrap(agentRead('app_'+key)),set:(key,value)=>unwrap(agentWrite('app_'+key,JSON.stringify(value)))};
        """)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["js/apps/portfolio/portfolio-app.js","js/apps/portfolio/spending-app.js","js/agent/agent-core.js","js/agent/agent-finance.js","js/agent/agent-web.js","js/agent/agent-stream.js","js/agent/agent-presentation.js"] {
            context.evaluateScript(try String(contentsOf:repo.appendingPathComponent(file),encoding:.utf8))
            XCTAssertNil(exception,file)
        }
        context.evaluateScript("""
        const io={get:key=>unwrap(agentRead(key)),set:(key,value)=>unwrap(agentWrite(key,JSON.stringify(value))),financeSummary:month=>AgentFinance.summary(month),portfolioTransaction:(row,deleting)=>AgentFinance.transaction(row,deleting)};
        AgentCore.execute('create_record',{collection:'notes',fields:{title:'From the phone',content:'Independent agent'}},io,{id:'phone-note',now:'2026-10-12T12:00:00Z',allowWrites:true});
        AgentCore.execute('create_record',{collection:'spending.accounts',fields:{name:'Checking',balance:{current:100}}},io,{id:'bank',now:'2026-10-12T12:00:00Z',allowWrites:true});
        """)
        XCTAssertNil(exception)
        XCTAssertEqual(try store.records("notes")[0]["title"] as? String,"From the phone")
        let request = context.evaluateScript("""
        AgentCore.request(AgentCore.defaults.anthropic,[{role:'user',content:'Read my notebook'},{role:'assistant',tool_calls:[{id:'call',type:'function',function:{name:'notebook_schema',arguments:'{}'}}]},{role:'tool',tool_call_id:'call',content:'{}'}],'2026-10-12T12:00:00Z',true)
        """)!.toDictionary()!
        XCTAssertNil(exception)
        XCTAssertEqual(request["url"] as? String,"https://api.anthropic.com/v1/messages")
        let body = request["body"] as! [String:Any], messages = body["messages"] as! [[String:Any]]
        XCTAssertEqual((messages.last!["content"] as! [[String:Any]])[0]["type"] as? String,"tool_result")
        let summary = context.evaluateScript("AgentCore.execute('finance_summary',{month:'2026-10'},io,{now:'2026-10-12T12:00:00Z'})")
        XCTAssertNil(exception); XCTAssertNotNil(summary?.toDictionary()?["spending"])
        let webSearch = context.evaluateScript("""
        AgentWeb.search(AgentWeb.prepare('web_search',{query:'Notebook'}),{Heading:'Notebook',AbstractText:'A writing book',AbstractURL:'https://example.com/notebook',AbstractSource:'Example'},'2026-10-12T12:00:00Z')
        """)!.toDictionary()!
        XCTAssertNil(exception); XCTAssertEqual(webSearch["provider"] as? String,"DuckDuckGo")
        let page = context.evaluateScript("""
        AgentWeb.page(AgentWeb.prepare('read_webpage',{url:'https://example.com/notebook'}),'<title>Source</title><script>ignore this</script><p>Public source text</p><a href="/more">More</a>','text/html','https://example.com/notebook','2026-10-12T12:00:00Z')
        """)!.toDictionary()!
        XCTAssertNil(exception); XCTAssertFalse((page["content"] as! String).contains("ignore this"))
        XCTAssertEqual((page["links"] as! [[String:Any]])[0]["url"] as? String,"https://example.com/more")
        context.evaluateScript("var reply = AgentStream.create('openai');")
        context.setObject("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Live text\"}}]}\n\n",forKeyedSubscript:"input" as NSString)
        XCTAssertEqual(context.evaluateScript("reply.feed(input)")?.toString(),"Live text")
        context.setObject("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",forKeyedSubscript:"input" as NSString)
        context.evaluateScript("reply.feed(input)")
        XCTAssertEqual(context.evaluateScript("AgentCore.response(AgentCore.defaults.openai,reply.finish()).content")?.toString(),"Live text")
        context.setObject("# News\n\n1. First\n\nDescription.\n\n2. Second\n\n```swift\nlet value = 1\n\n",forKeyedSubscript:"input" as NSString)
        let prose = context.evaluateScript("AgentPresentation.blocks(input)")!.toArray() as! [[String:Any]]
        XCTAssertEqual(prose.filter { $0["kind"] as? String == "item" }.map { $0["marker"] as! String },["1.","2."])
        XCTAssertEqual(prose.first?["level"] as? Int,1)
        XCTAssertFalse(context.evaluateScript("AgentPresentation.reveal(input)")!.toString()!.contains("let value"))
        XCTAssertNil(exception)
    }
}
