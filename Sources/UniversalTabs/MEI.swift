import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum MEIInterchange {
    public static func importDocument(_ data: Data) throws -> MusicXMLResult {
        let reader = MEIReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw MusicXMLError.malformed(parser.parserError?.localizedDescription ?? "invalid MEI") }
        guard reader.root == "mei" else { throw MusicXMLError.unsupported("expected an MEI document") }
        return MusicXMLResult(data: try reader.document(), diagnostics: reader.diagnostics)
    }

    public static func exportDocument(_ data: Data) throws -> MusicXMLResult {
        let document = try JSONDecoder().decode(UTabDocument.self, from: data)
        let meter = document.setup.time?.meter
        let count = meter?.numerator ?? 4
        let unit = meter?.denominator ?? 4
        var diagnostics: [String] = []
        var measures: [Int: [Int: [PerformanceEvent]]] = [:]
        for (staff, track) in document.tracks.enumerated() {
            for event in MusicXMLInterchange.expandedEvents(for: track, setup: document.setup) {
                measures[event.at.musical?.measure ?? 1, default: [:]][staff + 1, default: []].append(event)
            }
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<mei xmlns=\"http://www.music-encoding.org/ns/mei\" meiversion=\"5.1\"><meiHead><fileDesc><titleStmt><title>\(escape(document.utab.title ?? "Untitled"))</title></titleStmt><pubStmt/></fileDesc></meiHead><music><body><mdiv><score>"
        xml += "<scoreDef meter.count=\"\(count)\" meter.unit=\"\(unit)\"><staffGrp>"
        for (index, track) in document.tracks.enumerated() { xml += "<staffDef n=\"\(index + 1)\" lines=\"5\" label=\"\(escape(track.name ?? track.id))\"/>" }
        xml += "</staffGrp></scoreDef><section>"
        for measure in measures.keys.sorted() {
            xml += "<measure n=\"\(measure)\">"
            for staff in (measures[measure] ?? [:]).keys.sorted() {
                xml += "<staff n=\"\(staff)\"><layer n=\"1\">"
                let groups = Dictionary(grouping: measures[measure]?[staff] ?? [], by: eventPosition).sorted { $0.key < $1.key }.map(\.value)
                for group in groups {
                    let events = group.filter { $0.type == "rest" || $0.action != nil || $0.gesture != nil }
                    guard let first = events.first else { continue }
                    let duration = meiDuration(first.duration)
                    if first.type == "rest" { xml += "<rest \(duration)/>"; continue }
                    let notes = events.compactMap { meiNote($0, duration: events.count == 1 ? duration : nil) }
                    if notes.isEmpty { diagnostics.append("staff \(staff), measure \(measure): omitted event without a 12-EDO pitch") }
                    else if notes.count == 1 { xml += notes[0] }
                    else { xml += "<chord \(duration)>\(notes.joined())</chord>" }
                }
                xml += "</layer></staff>"
            }
            xml += "</measure>"
        }
        xml += "</section></score></mdiv></body></music></mei>"
        return MusicXMLResult(data: Data(xml.utf8), diagnostics: diagnostics)
    }

    private static func meiNote(_ event: PerformanceEvent, duration: String?) -> String? {
        guard let pitch = pitch(event.parameters?["pitch"]) else { return nil }
        let grace = event.type == "grace" ? " grace=\"unacc\"" : ""
        return "<note pname=\"\(pitch.name)\" oct=\"\(pitch.octave)\"\(pitch.accidental.map { " accid=\"\($0)\"" } ?? "")\(duration.map { " \($0)" } ?? "")\(grace)/>"
    }
    private static func pitch(_ value: JSONValue?) -> (name: String, octave: Int, accidental: String?)? {
        if case .object(let p)? = value, case .string(let tuning)? = p["tuning"], tuning == "12edo", case .number(let degreeValue)? = p["degree"], case .number(let periodValue)? = p["period"] {
            let d = Int(degreeValue); let names = [("c",nil),("c","s"),("d",nil),("e","f"),("e",nil),("f",nil),("f","s"),("g",nil),("g","s"),("a",nil),("b","f"),("b",nil)]
            let i = ((d % 12) + 12) % 12; return (names[i].0, Int(periodValue) + Int(floor(Double(d) / 12)), names[i].1)
        }
        guard case .string(let s)? = value, let first = s.first, let i = s.dropFirst().firstIndex(where: { $0.isNumber || $0 == "-" }), let octave = Int(s[i...]) else { return nil }
        let accidentalText = s[s.index(after: s.startIndex)..<i]; let accidental = accidentalText.first == "#" ? "s" : accidentalText.first == "b" ? "f" : nil
        return (String(first).lowercased(), octave, accidental)
    }
    private static func meiDuration(_ value: EventDuration?) -> String {
        let q = rational(value?.quarterNotes); let denominator = q > 0 ? max(1, Int((4 / q).rounded())) : 4
        return "dur=\"\(denominator)\""
    }
    private static func rational(_ value: JSONValue?) -> Double { if case .number(let n)? = value { return n }; guard case .string(let s)? = value else { return 0 }; let p=s.split(separator:"/"); if p.count==2,let a=Double(p[0]),let b=Double(p[1]),b != 0{return a/b};return Double(s) ?? 0 }
    private static func eventPosition(_ e: PerformanceEvent) -> Double { Double(e.at.musical?.beat ?? 1) + rational(e.at.musical?.offset) }
    private static func escape(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:"\"",with:"&quot;") }
}

private final class MEIReader: NSObject, XMLParserDelegate {
    struct Event { var measure=1; var staff=1; var layer=1; var name:String?; var octave:Int?; var accidental:String?; var duration=4; var rest=false; var grace=false; var chord=false }
    var root=""; var title="MEI import"; var meterCount=4; var meterUnit=4; var measure=1; var staff=1; var layer=1; var chordDepth=0; var current:Event?; var events:[Event]=[]; var text=""; var stack:[String]=[]; var diagnostics:[String]=[]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String:String] = [:]) {
        if root.isEmpty { root=name }; stack.append(name); text=""
        if name=="scoreDef" { meterCount=Int(a["meter.count"] ?? "") ?? 4; meterUnit=Int(a["meter.unit"] ?? "") ?? 4 }
        if name=="measure" { measure=Int(a["n"] ?? "") ?? measure }
        if name=="staff" { staff=Int(a["n"] ?? "") ?? staff }
        if name=="layer" { layer=Int(a["n"] ?? "") ?? layer }
        if name=="chord" { chordDepth += 1 }
        if name=="note" || name=="rest" { current = Event(measure:measure,staff:staff,layer:layer,name:a["pname"],octave:Int(a["oct"] ?? ""),accidental:a["accid"],duration:Int(a["dur"] ?? "") ?? 4,rest:name=="rest",grace:a["grace"] != nil,chord:chordDepth>0) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name=="title", title=="MEI import" { title=text.trimmingCharacters(in:.whitespacesAndNewlines) }; if (name=="note" || name=="rest"),let e=current { events.append(e);current=nil }; if name=="chord" { chordDepth-=1 }; _=stack.popLast();text="" }
    func document() throws -> Data {
        var tracks:[[String:Any]]=[]; let grouped=Dictionary(grouping:events,by:{"\($0.staff):\($0.layer)"})
        for (index, group) in grouped.sorted(by:{$0.key<$1.key}).enumerated() { var cursor:[Int:Double]=[:]; var output:[[String:Any]]=[]; for e in group.value { let q=4.0/Double(e.duration); let beat=(cursor[e.measure] ?? 0)+1; let at:[String:Any]=["musical":["measure":e.measure,"beat":Int(floor(beat)),"offset":String(format:"%.6g",beat-floor(beat))]]; var event:[String:Any]=["at":at,"duration":["quarterNotes":String(format:"%.6g",q)]]; if e.rest { event["type"]="rest" } else if let n=e.name,let o=e.octave { let acc=e.accidental=="s" ? "#" : e.accidental=="f" ? "b":""; event["action"]="play";event["target"]="notes";event["parameters"]=["pitch":"\(n.uppercased())\(acc)\(o)"];if e.grace{event["type"]="grace"} }; output.append(event); if !e.chord && !e.grace { cursor[e.measure]=(cursor[e.measure] ?? 0)+q } }; tracks.append(["id":"track-\(index+1)","instrument":"instrument-\(index+1)","events":output]) }
        let instruments=tracks.indices.map{["id":"instrument-\($0+1)","profile":"profile:mei"]}; let root:[String:Any]=["utab":["version":"0.1-draft","title":title],"setup":["profiles":[["id":"profile:mei","actuators":["notes":[:]],"interactions":["play":[:]]]],"instruments":instruments,"time":["meter":["numerator":meterCount,"denominator":meterUnit]]],"tracks":tracks]; return try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
    }
}
