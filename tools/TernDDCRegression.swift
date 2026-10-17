import Foundation
import CoreGraphics

final class FakeCLI: @unchecked Sendable {
 let folder:URL;let script:String
 init(_ name:String)throws{folder=FileManager.default.temporaryDirectory.appendingPathComponent("xdr-ddc-\(name)-\(UUID().uuidString)");script=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("fake-ddc.py").path;try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try "100".write(to:folder.appendingPathComponent("state"),atomically:true,encoding:.utf8);try "".write(to:folder.appendingPathComponent("commands.jsonl"),atomically:true,encoding:.utf8)}
 func run(_ args:[String])throws->String{let p=Process();let pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=[script,folder.path]+args;p.standardOutput=pipe;p.standardError=pipe;try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();guard p.terminationStatus==0 else{throw NSError(domain:"fake",code:1)};return String(data:data,encoding:.utf8)!.trimmingCharacters(in:.whitespacesAndNewlines)}
 deinit { try? FileManager.default.removeItem(at:folder) }
 var commands:[[String:Any]]{let text=(try?String(contentsOf:folder.appendingPathComponent("commands.jsonl"),encoding:.utf8)) ?? "";return text.split(separator:"\n").compactMap{try?JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}}
 var writes:[[String:Any]]{commands.filter{($0["command"] as? [String])?[2]=="set"}}
}
final class SlowFake: @unchecked Sendable {
 private let lock=NSLock();var hardware=100;var writes=[Int]();var wrongReadback=false
 func run(_ args:[String])throws->String{Thread.sleep(forTimeInterval:0.08);lock.lock();defer{lock.unlock()};if args[2]=="set"{hardware=Int(args[4])!;writes.append(hardware);return "Writing \(hardware)"};return String(wrongReadback ? hardware-1 : hardware)}
}
@main struct Tests {
 @MainActor static func settle(_ predicate:()->Bool)async {let deadline=ProcessInfo.processInfo.systemUptime+5;while !predicate() && ProcessInfo.processInfo.systemUptime<deadline {try? await Task.sleep(for:.milliseconds(10))};precondition(predicate(),"Timed out waiting for verified value")}
 @MainActor static func main()async throws{
  let start=Date().timeIntervalSince1970;let fake=try FakeCLI("drag");var persisted=[Int]();var results=[Double]()
  let c=TernDDCController(resolveDisplay:{_ in "FAKE"},commandRunner:{try fake.run($0)},persistBrightness:{persisted.append($0)})
  c.onResult={_,r in if case.success(let v)=r{results.append(v)}}
  for i in 0..<60 {c.setBrightness(Double(20+i)/100,for:42);try? await Task.sleep(for:.milliseconds(10))}
  precondition(!fake.writes.isEmpty,"Live dragging starved hardware writes")
  c.finishAdjustment(for:42);await settle{persisted.last==79}
  precondition(c.brightness(for:42)==0.79 && fake.writes.count<20)
  precondition(results.last==0.79)
  let before=fake.commands.count;try? await Task.sleep(for:.milliseconds(180));precondition(fake.commands.count==before,"Idle controller polled hardware")
  let first=fake.writes[0]["at"] as! Double;print("PASS live drag: first hardware write \(Int((first-start)*1000))ms;60 inputs -> \(fake.writes.count) writes,\(fake.commands.count) processes;final79 verified;no idle commands")
  c.shutdown()

  let burst=try FakeCLI("burst");var bp=[Int]();let b=TernDDCController(resolveDisplay:{_ in "FAKE"},commandRunner:{try burst.run($0)},persistBrightness:{bp.append($0)})
  for i in 0..<1000{b.setBrightness(Double(i%100)/100,for:42)};b.setBrightness(0.73,for:42);b.finishAdjustment(for:42)
  await settle{bp.last==73};precondition(burst.writes.count==1 && burst.commands.count==2)
  print("PASS burst:1001 inputs ->1 write+1 verification;latest73 wins")
  b.shutdown()

  let slow=SlowFake();var sp=[Int]();var callbacks=[Double]();let s=TernDDCController(resolveDisplay:{_ in "FAKE"},commandRunner:{try slow.run($0)},persistBrightness:{sp.append($0)},minimumWriteInterval:0)
  s.onResult={_,r in if case.success(let v)=r{callbacks.append(v)}}
  s.refresh(42);try? await Task.sleep(for:.milliseconds(10));s.setBrightness(0.8,for:42);precondition(s.brightness(for:42)==0.8)
  await settle{sp.last==80};precondition(callbacks==[0.8],"Old refresh published over the active gesture")
  for _ in 0..<5{s.setBrightness(s.brightness(for:42)-0.1,for:42)};s.finishAdjustment(for:42);await settle{sp.last==30};precondition(s.brightness(for:42)==0.3)
  print("PASS stale refresh suppressed;rapid hotkeys accumulate against latest intent")
  slow.wrongReadback=true;s.setBrightness(0.5,for:42);var failed=false;s.onResult={_,r in if case.failure=r{failed=true}}
  await settle{failed};precondition(s.brightness(for:42)==0.49 && sp.last==30,"Failed verification persisted an unconfirmed value")
  s.shutdown();print("PASS mismatched readback rolls back to actual49 and does not save50")

  let stop=SlowFake();var stopSaved=[Int]();let z=TernDDCController(resolveDisplay:{_ in "FAKE"},commandRunner:{try stop.run($0)},persistBrightness:{stopSaved.append($0)})
  z.setBrightness(0.4,for:42);try? await Task.sleep(for:.milliseconds(20));z.setBrightness(0.9,for:42);z.shutdown();try? await Task.sleep(for:.milliseconds(230));precondition(stop.writes==[40] && stopSaved.isEmpty,"Shutdown executed a queued obsolete write")
  print("PASS shutdown cancels queued writes and persistence;hardware untouched by these tests")
 }
}
