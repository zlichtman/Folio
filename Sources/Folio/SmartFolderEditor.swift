import SwiftUI
import AppKit
import ShelfCore

/// Make or change a smart folder: a name, all or any, and a list of rules, with a live count of what they gather.
extension AppController {
    @objc func newSmartFolder(_ sender: Any?) { editSmartFolder(nil) }
    @objc func editSmartFolderItem(_ sender: NSMenuItem) { editSmartFolder(sender.representedObject as? String) }
    var watchedFolderNames: [(id: String, name: String)] { ((try? database.connectedFolders()) ?? []).map { ($0.id,FolderWatcher.displayName($0.path)) } }
    /// Edits a smart folder, or makes one (from `starting` rules when given). `filtering` uses the same sheet to
    /// filter the place on screen instead: no name, and the count is of what's here.
    func editSmartFolder(_ id: String?, starting: SmartRules? = nil, filtering: Bool = false, created: (() -> Void)? = nil) {
        let existing = id.flatMap { id in (try? database.collections())?.first { $0.id == id } }
        let place = scope
        let model = SmartFolderModel(name:existing?.name ?? "", rules:existing?.rules ?? starting ?? SmartRules(rules:[SmartRule(.tag,.is,"")]),
                                     collections:regularCollections,folders:watchedFolderNames,
                                     count:{ [database] rules in (try? database?.count(rules:rules,in:filtering ? place : .all)) ?? 0 })
        let host = NSHostingController(rootView:SmartFolderEditor(model:model,isNew:existing == nil,filtering:filtering))
        smartFolderEditing = model
        model.finish = { [weak self, weak host] save in
            if let host { self?.window.contentViewController?.dismiss(host) }
            self?.smartFolderEditing = nil
            guard save, let self else { return }
            if filtering { self.setRuleFilter(model.saved); return }
            let name = model.name.trimmingCharacters(in:.whitespacesAndNewlines), rules = model.saved
            self.perform(existing == nil ? "New Smart Folder" : "Edit Smart Folder") { db in
                if let existing {
                    let before = try db.updateRules(existing.id,rules)
                    if name != existing.name { try db.renameCollection(existing.id,to:name) }
                    return before
                }
                let made = try db.createCollection(name:name,kind:.smart,rules:rules)
                DispatchQueue.main.async { self.pendingScope = .collection(made.id); created?() }
                return nil
            }
        }
        window.contentViewController?.presentAsSheet(host)
    }
}

final class SmartFolderModel: ObservableObject {
    struct Row: Identifiable { let id = UUID(); var rule: SmartRule }
    @Published var name: String
    @Published var match: SmartRules.Match
    @Published var rows: [Row] { didSet { recount() } }
    @Published private(set) var count = 0
    let collections: [(id: String, name: String)], folders: [(id: String, name: String)]
    private let groups: [SmartRules]
    private let counter: (SmartRules) -> Int
    var finish: ((Bool) -> Void)?
    init(name: String, rules: SmartRules, collections: [(id: String, name: String)], folders: [(id: String, name: String)] = [], count: @escaping (SmartRules) -> Int) {
        self.name = name; match = rules.match; rows = rules.rules.map { Row(rule:$0) }; groups = rules.groups
        self.collections = collections; self.folders = folders; counter = count
        recount()
    }
    /// What gets saved: rules with nothing to match on are left out, and nested groups from before are kept.
    var saved: SmartRules {
        SmartRules(match:match,rules:rows.map(\.rule).filter { !$0.value.trimmingCharacters(in:.whitespaces).isEmpty },groups:groups)
    }
    var canSave: Bool { !name.trimmingCharacters(in:.whitespaces).isEmpty && (!saved.rules.isEmpty || !groups.isEmpty) }
    func recount() {
        let rules = saved
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            let n = rules.rules.isEmpty && rules.groups.isEmpty ? 0 : counter(rules)
            DispatchQueue.main.async { self.count = n }
        }
    }
    func add() { rows.append(Row(rule:SmartRule(.tag,.is,""))) }
    func remove(_ id: UUID) { rows.removeAll { $0.id == id } }
    /// Changing what a rule looks at resets it to that field's first comparison and a sensible starting value.
    func setField(_ id: UUID, _ field: SmartRule.Field) {
        guard let i = rows.firstIndex(where:{ $0.id == id }) else { return }
        let first = SmartFolderEditor.ops(field)[0]
        rows[i].rule = SmartRule(field,first,SmartFolderEditor.starting(field,collections,folders))
    }
    func setOp(_ id: UUID, _ op: SmartRule.Op) { if let i = rows.firstIndex(where:{ $0.id == id }) { rows[i].rule.op = op } }
    func setValue(_ id: UUID, _ value: String) { if let i = rows.firstIndex(where:{ $0.id == id }) { rows[i].rule.value = value } }
}

struct SmartFolderEditor: View {
    @ObservedObject var model: SmartFolderModel
    let isNew: Bool
    var filtering = false

    static let fields: [(SmartRule.Field, String)] = [(.tag,"Tag"),(.kind,"Kind"),(.name,"Name"),(.text,"Any text"),(.color,"Color"),(.added,"Date added"),
        (.liked,"Liked"),(.untagged,"Untagged"),(.hasText,"Has text in it"),(.orientation,"Shape"),(.width,"Width"),(.height,"Height"),
        (.ext,"File type"),(.size,"File size"),(.duration,"Video length"),(.created,"Date created"),(.domain,"Website"),(.collection,"Collection"),
        (.folder,"Watched folder")]
    static func ops(_ field: SmartRule.Field) -> [SmartRule.Op] {
        switch field {
        case .kind, .ext, .collection, .folder: return [.is,.isNot]
        case .size, .duration: return [.greater,.less]
        case .created: return [.within,.notWithin]
        case .tag: return [.is,.isNot,.contains,.notContains]
        case .name: return [.contains,.notContains,.is,.begins]
        case .text: return [.contains,.notContains]
        case .domain: return [.is,.contains,.notContains]
        case .added: return [.within,.notWithin]
        case .width, .height: return [.greater,.less]
        case .color, .orientation, .liked, .untagged, .hasText: return [.is]
        }
    }
    static func opTitle(_ op: SmartRule.Op) -> String {
        switch op {
        case .is: return "is"; case .isNot: return "is not"; case .contains: return "contains"; case .notContains: return "doesn't contain"
        case .begins: return "begins with"; case .greater: return "is more than"; case .less: return "is less than"
        case .within: return "is in the last"; case .notWithin: return "is not in the last"
        }
    }
    static func starting(_ field: SmartRule.Field, _ collections: [(id: String, name: String)], _ folders: [(id: String, name: String)] = []) -> String {
        switch field {
        case .kind: return "image"; case .orientation: return "landscape"; case .liked, .untagged, .hasText: return "true"
        case .added: return "7"; case .width, .height: return "1000"; case .collection: return collections.first?.id ?? ""
        case .size: return "10"; case .duration: return "30"; case .created: return "30"; case .folder: return folders.first?.id ?? ""
        default: return ""
        }
    }
    /// One line naming the rules, for menus: "Kind is Image · Width is more than 400 pixels".
    static func summary(_ rules: SmartRules, collections: [(id: String, name: String)], folders: [(id: String, name: String)]) -> String {
        let parts = rules.rules.map { rule -> String in
            let field = fields.first { $0.0 == rule.field }?.1 ?? rule.field.rawValue
            switch rule.field {
            case .liked, .untagged, .hasText: return rule.value == "false" ? "\(field): no" : field
            default: break
            }
            let value: String
            switch rule.field {
            case .collection: value = collections.first { $0.id == rule.value }?.name ?? rule.value
            case .folder: value = folders.first { $0.id == rule.value }?.name ?? rule.value
            case .kind: value = rule.value.split(separator:",").map { k in kinds.first { $0.0 == k }?.1 ?? String(k) }.joined(separator:", ")
            case .orientation: value = rule.value.capitalized
            case .added, .created: value = "\(rule.value) days"
            case .size: value = "\(rule.value) MB"
            case .duration: value = "\(rule.value) seconds"
            case .width, .height: value = "\(rule.value) pixels"
            default: value = "\u{201C}\(rule.value)\u{201D}"
            }
            return "\(field) \(opTitle(rule.op)) \(value)"
        }
        return parts.joined(separator:rules.match == .all ? " · " : " or ")
    }
    static let kinds = [("image","Image"),("video","Video"),("gif","GIF"),("link","Link"),("color","Color")]

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(filtering ? "Filter" : isNew ? "New Smart Folder" : "Edit Smart Folder").font(.headline)
            if !filtering { TextField("Name",text:$model.name).textFieldStyle(.roundedBorder) }
            HStack(spacing:6) {
                Text(filtering ? "Show items here that match" : "Gather items that match")
                Picker("",selection:$model.match) { Text("all").tag(SmartRules.Match.all); Text("any").tag(SmartRules.Match.any) }
                    .labelsHidden().fixedSize()
                Text("of these:")
            }
            VStack(spacing:8) {
                ForEach(model.rows) { row in ruleRow(row) }
            }
            HStack {
                Button { model.add() } label: { Label("Add Rule",systemImage:"plus") }
                Spacer()
                Text(model.count == 1 ? "1 item" : "\(model.count.formatted()) items").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.finish?(false) }.keyboardShortcut(.cancelAction)
                Button(filtering ? "Filter" : isNew ? "Create" : "Save") { model.finish?(true) }.keyboardShortcut(.defaultAction)
                    .disabled(filtering ? model.saved.rules.isEmpty : !model.canSave)
            }
        }
        .padding(20).frame(width:560)
    }

    @ViewBuilder private func ruleRow(_ row: SmartFolderModel.Row) -> some View {
        let rule = row.rule
        HStack(spacing:8) {
            Picker("",selection:Binding(get:{ rule.field },set:{ model.setField(row.id,$0) })) {
                ForEach(Self.fields.filter { field in (field.0 != .folder || !model.folders.isEmpty) && (field.0 != .collection || !model.collections.isEmpty) },id:\.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().fixedSize().frame(width:140,alignment:.leading)
            let ops = Self.ops(rule.field)
            if ops.count > 1 {
                Picker("",selection:Binding(get:{ rule.op },set:{ model.setOp(row.id,$0) })) {
                    ForEach(ops,id:\.self) { Text(Self.opTitle($0)).tag($0) }
                }.labelsHidden().fixedSize().frame(width:150,alignment:.leading)
            } else { Text(Self.opTitle(ops[0])).foregroundStyle(.secondary).padding(.leading,9).frame(width:150,alignment:.leading) }
            value(row)
            Spacer(minLength:0)
            Button { model.remove(row.id) } label: { Image(systemName:"minus.circle") }
                .buttonStyle(.borderless).help("Remove this rule").disabled(model.rows.count == 1)
        }
    }

    @ViewBuilder private func value(_ row: SmartFolderModel.Row) -> some View {
        let rule = row.rule
        let text = Binding(get:{ rule.value },set:{ model.setValue(row.id,$0) })
        switch rule.field {
        case .kind:
            Picker("",selection:text) { ForEach(Self.kinds,id:\.0) { Text($0.1).tag($0.0) } }.labelsHidden().fixedSize()
        case .orientation:
            Picker("",selection:text) { Text("Landscape").tag("landscape"); Text("Portrait").tag("portrait"); Text("Square").tag("square") }.labelsHidden().fixedSize()
        case .liked, .untagged, .hasText:
            Picker("",selection:text) { Text("Yes").tag("true"); Text("No").tag("false") }.labelsHidden().fixedSize()
        case .collection:
            Picker("",selection:text) { ForEach(model.collections,id:\.id) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
        case .folder:
            Picker("",selection:text) { ForEach(model.folders,id:\.id) { Text($0.name).tag($0.id) } }.labelsHidden().fixedSize()
        case .added, .created:
            HStack(spacing:6) { TextField("",text:text).textFieldStyle(.roundedBorder).frame(width:56); Text("days").foregroundStyle(.secondary) }
        case .size:
            HStack(spacing:6) { TextField("",text:text).textFieldStyle(.roundedBorder).frame(width:72); Text("MB").foregroundStyle(.secondary) }
        case .duration:
            HStack(spacing:6) { TextField("",text:text).textFieldStyle(.roundedBorder).frame(width:72); Text("seconds").foregroundStyle(.secondary) }
        case .width, .height:
            HStack(spacing:6) { TextField("",text:text).textFieldStyle(.roundedBorder).frame(width:72); Text("pixels").foregroundStyle(.secondary) }
        default:
            TextField(Self.placeholder(rule.field),text:text).textFieldStyle(.roundedBorder)
        }
    }
    static func placeholder(_ field: SmartRule.Field) -> String {
        switch field {
        case .tag: return "sunset"; case .name: return "Screenshot"; case .text: return "words in names, notes or images"
        case .color: return "#e07a5f or red"; case .ext: return "jpg, png"; case .domain: return "dribbble.com"
        default: return ""
        }
    }
}
