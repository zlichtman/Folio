import AppKit
import ImageIO
import ShelfCore

/// The details panel for the selection: one item in full, or what several have in common.
final class Inspector: NSObject, NSTextFieldDelegate {
    weak var app: AppController?
    let view = NSView()
    private let preview = PreviewImageView()
    private let title = NSTextField()
    private let meta = label("",size:11,color:Theme.muted)
    private let like = NSButton(), open = NSButton(), reveal = NSButton(), trash = NSButton()
    private let tags = TagFlowView(), suggestions = TagFlowView(), collections = TagFlowView()
    private let addTag = NSTextField()
    private let addCollection = NSPopUpButton(frame:.zero,pullsDown:true)
    private let note = NSTextField()
    private let text = NSTextField(wrappingLabelWithString:"")
    /// What the Mac's model saw in the picture: its sentence, without the keywords.
    private let seen = NSTextField(wrappingLabelWithString:"")
    private let source = NSTextField(), author = NSTextField(), visit = NSButton()
    private let swatches = SwatchRow()
    private let camera = NSTextField(wrappingLabelWithString:"")
    private let empty = label("Select an item to see its details",size:13,color:.secondaryLabelColor)
    /// With nothing selected: what's in the place on screen.
    private let summaryTitle = label("",size:15,weight:.semibold,color:Theme.ink), summary = label("",size:12,color:Theme.muted)
    var place: (() -> (title: String, items: [ShelfItem]))?
    private let emptyView = NSStackView()
    private var sections: [String:NSView] = [:]
    private var stack: NSStackView!
    private(set) var items: [ShelfItem] = []
    private var token = 0
    /// Suggested tags: the user's own tags from look-alike items, then the Mac's labels for a single item.
    private var learnt: [String] = [], labels: [String] = []
    var item: ShelfItem? { items.count == 1 ? items[0] : nil }
    var swatchColors: [String] { swatches.colors }
    func pickSwatch(_ index: Int) { if swatches.colors.indices.contains(index) { swatches.pick?(swatches.colors[index]) } }

    init(app: AppController) {
        self.app = app
        super.init()
        preview.heightAnchor.constraint(equalToConstant:190).isActive = true
        title.font = .systemFont(ofSize:15,weight:.semibold); title.textColor = Theme.ink
        title.isBordered = false; title.drawsBackground = false; title.focusRingType = .none
        title.maximumNumberOfLines = 3; title.lineBreakMode = .byWordWrapping; title.cell?.wraps = true
        title.delegate = self; title.placeholderString = "Untitled"
        for (button,symbol,tip,action) in [(like,"heart","Like · L",#selector(toggleLike)),(open,"arrow.up.forward.app","Open with the default app",#selector(openOriginal)),
                                           (reveal,"folder","Show in Finder · ⇧⌘R",#selector(showInFinder)),(trash,"trash","Move to Trash · ⌘⌫",#selector(moveToTrash))] {
            // Borderless icons, so actions don't look like the tag chips below them.
            button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:tip); button.toolTip = tip
            button.bezelStyle = .accessoryBarAction; button.isBordered = false; button.target = self; button.action = action
            button.symbolConfiguration = .init(pointSize:15,weight:.regular); button.contentTintColor = .secondaryLabelColor
            button.widthAnchor.constraint(equalToConstant:28).isActive = true; button.heightAnchor.constraint(equalToConstant:28).isActive = true
        }
        let actions = NSStackView(views:[like,open,reveal,NSView(),trash]); actions.spacing = 4
        addTag.placeholderAttributedString = NSAttributedString(string:"Add tag…",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.tertiaryLabelColor])
        addTag.font = .systemFont(ofSize:12)
        addTag.isBezeled = false; addTag.isBordered = false; addTag.drawsBackground = false; addTag.focusRingType = .none
        addTag.delegate = self; addTag.target = self; addTag.action = #selector(commitTag)
        addCollection.bezelStyle = .inline; addCollection.isBordered = false; addCollection.font = .systemFont(ofSize:11)
        note.placeholderString = "Add a note"; note.font = .systemFont(ofSize:12); note.delegate = self
        note.isBezeled = false; note.isBordered = false; note.drawsBackground = false; note.focusRingType = .none
        note.cell?.wraps = true; note.cell?.isScrollable = false; note.maximumNumberOfLines = 0
        text.font = .systemFont(ofSize:11); text.textColor = Theme.muted; text.isSelectable = true; text.maximumNumberOfLines = 10
        seen.font = .systemFont(ofSize:12); seen.textColor = Theme.ink; seen.isSelectable = true; seen.maximumNumberOfLines = 6
        // Inline fields like the tag field: who made it and where it came from, both editable.
        for (field,hint) in [(author,"Add an author"),(source,"Add a link")] {
            field.placeholderAttributedString = NSAttributedString(string:hint,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.tertiaryLabelColor])
            field.font = .systemFont(ofSize:12); field.textColor = Theme.ink; field.delegate = self; field.lineBreakMode = .byTruncatingMiddle
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        }
        visit.image = NSImage(systemSymbolName:"arrow.up.right",accessibilityDescription:"Open the link"); visit.toolTip = "Open the link"
        visit.isBordered = false; visit.contentTintColor = Theme.muted; visit.target = self; visit.action = #selector(openSource)
        visit.setContentHuggingPriority(.required,for:.horizontal)
        let sourceRow = NSStackView(views:[source,visit]); sourceRow.orientation = .horizontal; sourceRow.spacing = 6
        let collectionHeader = NSStackView(views:[sectionLabel("Collections",key:"collect",action:"add to a collection"),NSView(),addCollection]); collectionHeader.orientation = .horizontal
        func section(_ name: String, _ header: NSView, _ body: [NSView]) -> NSView {
            let box = NSStackView(views:[header] + body); box.orientation = .vertical; box.alignment = .leading; box.spacing = 7
            for view in [header] + body { view.translatesAutoresizingMaskIntoConstraints = false }
            sections[name] = box; return box
        }
        let tagSection = section("tags",sectionLabel("Tags",key:"tags",action:"add tags"),[tags,addTag])
        let suggestionSection = section("suggestions",sectionLabel("Suggested"),[suggestions])
        let collectionSection = section("collections",collectionHeader,[collections])
        let noteBox = Surface(NSColor.labelColor.withAlphaComponent(0.04),radius:8,stroke:.separatorColor); note.translatesAutoresizingMaskIntoConstraints = false; noteBox.addSubview(note)
        NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo:noteBox.leadingAnchor,constant:8),note.trailingAnchor.constraint(equalTo:noteBox.trailingAnchor,constant:-8),
                                     note.topAnchor.constraint(equalTo:noteBox.topAnchor,constant:7),note.bottomAnchor.constraint(equalTo:noteBox.bottomAnchor,constant:-7),
                                     noteBox.heightAnchor.constraint(greaterThanOrEqualToConstant:54)])
        let noteSection = section("note",sectionLabel("Note",key:"note",action:"edit the note"),[noteBox])
        let textSection = section("text",sectionLabel("Text in image"),[text])
        let seenSection = section("seen",sectionLabel("What your Mac sees"),[seen])
        let sourceSection = section("source",sectionLabel("Source",key:"source",action:"edit the source link"),[sourceRow])
        let authorSection = section("author",sectionLabel("Author",key:"author",action:"edit the author"),[author])
        let sampler = NSButton(image:NSImage(systemSymbolName:"eyedropper",accessibilityDescription:"Pick a color on screen")!,target:self,action:#selector(sampleColor))
        sampler.isBordered = false; sampler.contentTintColor = Theme.muted; sampler.toolTip = "Pick any color on your screen and find items that use it"
        let dice = NSButton(image:NSImage(systemSymbolName:"dice",accessibilityDescription:"Search a random colour")!,target:self,action:#selector(randomColor))
        dice.isBordered = false; dice.contentTintColor = Theme.muted; dice.toolTip = "Search a colour picked at random from your library"
        let colorHeader = NSStackView(views:[sectionLabel("Colors"),NSView(),dice,sampler]); colorHeader.orientation = .horizontal; colorHeader.spacing = 10
        swatches.pick = { [weak self] hex in self?.app?.runSearch(hex) }
        swatches.menuProvider = { [weak self] hex in self?.swatchMenu(hex) }
        let colorSection = section("colors",colorHeader,[swatches])
        camera.font = .systemFont(ofSize:11.5); camera.textColor = Theme.ink; camera.isSelectable = true
        let cameraSection = section("camera",sectionLabel("Camera"),[camera])
        let emptyIcon = NSImageView(image:NSImage(systemSymbolName:"sidebar.right",accessibilityDescription:nil)!)
        emptyIcon.symbolConfiguration = .init(pointSize:26,weight:.light); emptyIcon.contentTintColor = .tertiaryLabelColor
        summary.alignment = .center; summary.maximumNumberOfLines = 0; summaryTitle.alignment = .center
        emptyView.setViews([summaryTitle,summary,emptyIcon,empty],in:.center); emptyView.orientation = .vertical; emptyView.spacing = 8
        emptyView.setCustomSpacing(28,after:summary)
        emptyView.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(emptyView)
        NSLayoutConstraint.activate([emptyView.centerXAnchor.constraint(equalTo:view.centerXAnchor),emptyView.centerYAnchor.constraint(equalTo:view.centerYAnchor,constant:-20)])
        stack = NSStackView(views:[preview,title,meta,actions,tagSection,suggestionSection,seenSection,colorSection,collectionSection,noteSection,authorSection,sourceSection,textSection,cameraSection])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12,after:preview); stack.setCustomSpacing(4,after:title); stack.setCustomSpacing(12,after:meta)
        let scroller = NSScrollView(); scroller.drawsBackground = false; scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true
        scroller.automaticallyAdjustsContentInsets = false
        let document = InspectorDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroller.documentView = document; document.addSubview(stack)
        scroller.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroller)
        NSLayoutConstraint.activate([scroller.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroller.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            scroller.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroller.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo:scroller.contentView.leadingAnchor),document.widthAnchor.constraint(equalTo:scroller.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo:scroller.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-16),
            stack.topAnchor.constraint(equalTo:document.topAnchor,constant:8),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24)])
        for view in [preview,title,meta,actions,tags,addTag,suggestions,collections,noteBox,text,seen,sourceRow,author,collectionHeader,colorHeader,swatches,camera] + Array(sections.values) {
            view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        show([])
    }

    /// Shows the selection. Pass `keepEdits` when the same items reloaded, so typing in progress survives.
    func show(_ items: [ShelfItem], keepEdits: Bool = false) {
        let same = keepEdits && items.map(\.id) == self.items.map(\.id)
        self.items = items; token += 1
        let none = items.isEmpty, single = items.count == 1
        emptyView.isHidden = !none; stack.isHidden = none
        if none { describePlace() }
        for view in [preview,title,meta,like.superview!] as [NSView] { view.isHidden = none }
        for name in ["tags","collections"] { sections[name]?.isHidden = none }
        for name in ["text","seen","colors","camera"] { sections[name]?.isHidden = !single }
        learnt = []; labels = []; sections["suggestions"]?.isHidden = true
        if !none {
            let ticket = token
            app?.tagsFromLookalikes(items) { [weak self] tags in
                guard let self, self.token == ticket else { return }
                self.learnt = tags; self.showSuggestions()
            }
        }
        sections["note"]?.isHidden = none
        // Author and source go on several items at once too; a link's own address isn't a source to overwrite.
        sections["author"]?.isHidden = none
        sections["source"]?.isHidden = none || (!single && items.allSatisfy { $0.kind == "link" })
        // The slots stay put for several items; actions that need one item just dim.
        open.isEnabled = single; reveal.isEnabled = single
        guard let first = items.first else { return }
        let editing = app?.window.firstResponder as? NSTextView
        if !same || editing?.delegate as? NSTextField !== title { title.stringValue = single ? first.title : "\(items.count) items" }
        title.isEditable = single
        // Several items share a note only when they already agree; typing gives them all the new one.
        let sharedNote = items.allSatisfy { $0.note == first.note } ? first.note : ""
        if !same || editing?.delegate as? NSTextField !== note { note.stringValue = sharedNote }
        note.placeholderString = single ? "Add a note" : sharedNote.isEmpty && !items.allSatisfy({ $0.note.isEmpty }) ? "Mixed notes · type to replace all" : "Add a note to all \(items.count)"
        if single {
            if !same || editing?.delegate as? NSTextField !== author { author.stringValue = first.author }
            if !same || editing?.delegate as? NSTextField !== source { source.stringValue = first.kind == "link" ? first.url : first.source }
            source.isEditable = first.kind != "link"
            hint(author,"Add an author"); hint(source,"Add a link")
        } else {
            let editable = items.filter { $0.kind != "link" }
            let sharedAuthor = items.allSatisfy { $0.author == first.author } ? first.author : nil
            let sharedSource = editable.allSatisfy { $0.source == editable.first?.source } ? editable.first?.source : nil
            if !same || editing?.delegate as? NSTextField !== author { author.stringValue = sharedAuthor ?? "" }
            if !same || editing?.delegate as? NSTextField !== source { source.stringValue = sharedSource ?? "" }
            source.isEditable = true
            hint(author,sharedAuthor == nil ? "Mixed · type to replace all" : "Add an author to all \(items.count)")
            hint(source,sharedSource == nil ? "Mixed · type to replace all" : "Add a link to all \(editable.count)")
        }
        visit.isHidden = !(source.stringValue.hasPrefix("http"))
        meta.stringValue = single ? Self.describe(first) : Self.describe(items)
        let liked = items.allSatisfy(\.liked)
        like.image = NSImage(systemSymbolName:liked ? "heart.fill" : "heart",accessibilityDescription:liked ? "Unlike" : "Like")?
            .withSymbolConfiguration(.init(paletteColors:[liked ? .systemPink : .labelColor]))
        trash.toolTip = app?.inTrash == true ? "Delete Immediately…" : "Move to Trash · ⌘⌫"
        // Tags every selected item shares; one item shows its own and its automatic tags.
        let shared = items.dropFirst().reduce(Set((first.tags + first.autoTags).map { $0.lowercased() })) { $0.intersection(($1.tags + $1.autoTags).map { $0.lowercased() }) }
        let shown = Tags.clean(first.tags + first.autoTags).filter { shared.contains($0.lowercased()) }
        let own = Set(first.tags.map { $0.lowercased() })
        tags.setTags(shown.map { tagTitle($0,automatic:!own.contains($0.lowercased())) },ids:shown,target:self,action:#selector(searchTag(_:)),menu:{ [weak self] tag in self?.tagMenu(tag) })
        let names = app?.collectionNames ?? [:]
        let common = items.dropFirst().reduce(Set(first.collections)) { $0.intersection($1.collections) }
        let chips = first.collections.filter { common.contains($0) }.compactMap { id in names[id].map { (id,$0) } }
        collections.setTags(chips.map(\.1),ids:chips.map(\.0),target:self,action:#selector(showCollection(_:)),menu:{ [weak self] id in self?.collectionMenu(id) })
        rebuildCollectionMenu()
        if single { preview.stack = []; loadPreview(first) } else { loadStack(Array(items.prefix(3))) }
        swatches.colors = single ? first.colors : []
        sections["colors"]?.isHidden = !single || first.colors.isEmpty
        if single { loadDetails(first) }
    }
    /// "24 items · 180 MB" and what kinds they are, for the place on screen.
    func describePlace() {
        guard let (name,all) = place?(), !all.isEmpty else { summaryTitle.isHidden = true; summary.isHidden = true; return }
        summaryTitle.isHidden = false; summary.isHidden = false; summaryTitle.stringValue = name
        let size = all.reduce(Int64(0)) { $0 + $1.fileSize }
        var lines = [(all.count == 1 ? "1 item" : "\(all.count.formatted()) items") + (size > 0 ? " · " + ByteCountFormatter.string(fromByteCount:size,countStyle:.file) : "")]
        let kinds = [("image","picture","pictures"),("video","video","videos"),("gif","GIF","GIFs"),("link","link","links"),("color","color","colors")]
        let counts = kinds.compactMap { kind, one, many -> String? in
            let n = all.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n.formatted()) \(n == 1 ? one : many)"
        }
        if counts.count > 1 { lines.append(counts.joined(separator:" · ")) }
        let liked = all.filter(\.liked).count
        if liked > 0 { lines.append("\(liked.formatted()) liked") }
        summary.stringValue = lines.joined(separator:"\n")
    }
    func focusNote() { app?.window.makeFirstResponder(note) }
    func focusAuthor() { if !items.isEmpty { app?.window.makeFirstResponder(author) } }
    func focusSource() { if !items.isEmpty, source.isEditable { app?.window.makeFirstResponder(source) } }
    private func hint(_ field: NSTextField, _ text: String) {
        field.placeholderAttributedString = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.tertiaryLabelColor])
    }
    static func describe(_ item: ShelfItem) -> String {
        var parts: [String] = []
        if item.width > 0, item.kind == "image" { parts.append("\(Int(item.width)) × \(Int(item.height))") }
        if item.kind == "video", item.duration > 0 { parts.append(Duration.seconds(item.duration).formatted(.time(pattern:.minuteSecond))) }
        parts.append(item.ext.isEmpty ? item.kind.capitalized : item.ext.uppercased())
        if item.fileSize > 0 { parts.append(ByteCountFormatter.string(fromByteCount:item.fileSize,countStyle:.file)) }
        parts.append("Added " + Date(timeIntervalSince1970:item.added).formatted(date:.abbreviated,time:.omitted))
        return parts.joined(separator:"  ·  ")
    }
    static func describe(_ items: [ShelfItem]) -> String {
        let size = items.reduce(Int64(0)) { $0 + $1.fileSize }
        return size > 0 ? ByteCountFormatter.string(fromByteCount:size,countStyle:.file) : "Selected"
    }
    private func loadPreview(_ item: ShelfItem) {
        let ticket = token
        guard item.path.hasPrefix("/") else { preview.image = nil; return }
        app?.thumbnails.request(path:item.path,pixels:512) { [weak self] image in
            guard let self, self.token == ticket else { return }
            self.preview.image = image
        }
    }
    private func loadStack(_ chosen: [ShelfItem]) {
        let ticket = token; preview.image = nil
        var images: [Int:CGImage] = [:]
        for (index,item) in chosen.enumerated() {
            guard item.path.hasPrefix("/") else {
                // Colours and links without a picture still take their place in the fan.
                if let card = standIn(item) { images[index] = card; preview.stack = images.keys.sorted().compactMap { images[$0] } }
                continue
            }
            app?.thumbnails.request(path:item.path,pixels:512) { [weak self] image in
                guard let self, self.token == ticket, let image else { return }
                images[index] = image; self.preview.stack = images.keys.sorted().compactMap { images[$0] }
            }
        }
    }
    /// A small picture for an item that has none: a colour's swatch, or a link's title on a card.
    private func standIn(_ item: ShelfItem) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:480,pixelsHigh:480,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { return nil }
        rep.size = NSSize(width:240,height:240)
        guard let context = NSGraphicsContext(bitmapImageRep:rep) else { return nil }
        let rect = NSRect(x:0,y:0,width:240,height:240)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        preview.effectiveAppearance.performAsCurrentDrawingAppearance {
            if item.kind == "color", let value = item.colors.first.flatMap(Theme.rgb) {
                Theme.color(value).setFill(); rect.fill()
            } else {
                Theme.chip.setFill(); rect.fill()
                let text = NSAttributedString(string:item.title,attributes:[.font:NSFont.systemFont(ofSize:22,weight:.semibold),.foregroundColor:Theme.ink])
                text.draw(with:rect.insetBy(dx:20,dy:20),options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    /// Tags from look-alikes come first, written as the user wrote them; the Mac's own labels fill in after.
    private func showSuggestions() {
        guard let first = items.first else { return }
        // A tag every selected item already has isn't a suggestion; one only some have still is.
        let have = items.dropFirst().reduce(Set((first.tags + first.autoTags).map { $0.lowercased() })) { $0.intersection(($1.tags + $1.autoTags).map { $0.lowercased() }) }
        let mine = learnt.filter { !have.contains($0.lowercased()) }
        var seen = Set(mine.map { $0.lowercased() })
        let theirs = labels.filter { !have.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        let picks = Array((mine + theirs).prefix(8)), learntSet = Set(mine)
        suggestions.setTags(picks.map { tagTitle($0,automatic:!learntSet.contains($0)) },ids:picks,target:self,action:#selector(acceptSuggestion(_:)))
        sections["suggestions"]?.isHidden = picks.isEmpty
    }
    private func loadDetails(_ item: ShelfItem) {
        let ticket = token
        app?.workQueue.async { [weak self] in
            guard let database = self?.app?.database else { return }
            let full = try? database.item(id:item.id), analysis = try? database.analysis(id:item.id)
            let cameraLines = item.kind == "image" ? Self.cameraDetails(item.path) : []
            DispatchQueue.main.async {
                guard let self, self.token == ticket else { return }
                self.labels = (analysis?.suggestions ?? []).map(\.label); self.showSuggestions()
                let ocr = (full?.ocr ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                self.text.stringValue = ocr.count > 600 ? String(ocr.prefix(600)) + "…" : ocr
                self.sections["text"]?.isHidden = ocr.isEmpty
                let sentence = (full?.seen ?? "").split(whereSeparator:\.isNewline).first.map { $0.trimmingCharacters(in:.whitespaces) } ?? ""
                self.seen.stringValue = sentence; self.sections["seen"]?.isHidden = sentence.isEmpty
                self.camera.stringValue = cameraLines.joined(separator:"\n")
                self.sections["camera"]?.isHidden = cameraLines.isEmpty
            }
        }
    }
    /// Camera, lens and exposure from a photo's metadata, a line each.
    static func cameraDetails(_ path: String) -> [String] {
        guard path.hasPrefix("/"), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else { return [] }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any] ?? [:]
        var lines: [String] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in:.whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in:.whitespaces)
        let body = model.lowercased().hasPrefix(make.lowercased()) ? model : [make,model].filter { !$0.isEmpty }.joined(separator:" ")
        if !body.isEmpty { lines.append(body) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty, lens != body { lines.append(lens) }
        var exposure: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append(String(format:"%g mm",(focal*10).rounded()/10)) }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format:"ƒ/%g",(f*10).rounded()/10)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 { exposure.append(t >= 1 ? String(format:"%g s",t) : "1/\(Int((1/t).rounded())) s") }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 { exposure.append(String(format:"%+g EV",(bias*10).rounded()/10)) }
        if !exposure.isEmpty { lines.append(exposure.joined(separator:"  ·  ")) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parse = DateFormatter(); parse.locale = Locale(identifier:"en_US_POSIX"); parse.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = parse.date(from:taken) { lines.append("Taken " + date.formatted(date:.abbreviated,time:.shortened)) }
        }
        return lines
    }
    private func swatchMenu(_ hex: String) -> NSMenu {
        let menu = NSMenu()
        for (title,value) in [("Find Items with This Color","find:" + hex),("Save to Colors","save:" + hex),("Copy \(hex.uppercased())",hex.uppercased()),
                              ("Copy as RGB",Self.rgbString(hex))] {
            let entry = NSMenuItem(title:title,action:#selector(swatchAction(_:)),keyEquivalent:""); entry.target = self
            entry.representedObject = value; menu.addItem(entry)
        }
        return menu
    }
    static func rgbString(_ hex: String) -> String {
        let v = UInt32(hex.trimmingCharacters(in:CharacterSet(charactersIn:"#")),radix:16) ?? 0
        return "rgb(\((v>>16)&255), \((v>>8)&255), \(v&255))"
    }
    @objc private func swatchAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value.hasPrefix("find:") { app?.runSearch(String(value.dropFirst(5))); return }
        if value.hasPrefix("save:") { app?.saveColors([String(value.dropFirst(5))]); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string); app?.notify("Copied \(value)")
    }
    @objc private func sampleColor() {
        NSColorSampler().show { [weak self] color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format:"#%02x%02x%02x",Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255))
            self?.app?.runSearch(hex)
        }
    }

    // MARK: Collections

    private func rebuildCollectionMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle:"Add to Collection",action:nil,keyEquivalent:"").image = NSImage(systemSymbolName:"plus",accessibilityDescription:"Add to collection")
        for (id,name) in app?.regularCollections ?? [] {
            let entry = NSMenuItem(title:name,action:#selector(addToCollection(_:)),keyEquivalent:""); entry.target = self; entry.representedObject = id
            entry.state = items.allSatisfy { $0.collections.contains(id) } ? .on : .off
            menu.addItem(entry)
        }
        if menu.items.count > 1 { menu.addItem(.separator()) }
        let new = NSMenuItem(title:"New Collection…",action:#selector(AppController.newCollection(_:)),keyEquivalent:"")
        new.target = app; new.identifier = .init("withSelection"); menu.addItem(new)
        addCollection.menu = menu
    }
    @objc private func addToCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if sender.state == .on { app?.removeFromCollection(items,id:id) } else { app?.addToCollection(items,id:id,name:sender.title) }
    }
    @objc private func showCollection(_ sender: NSButton) { if let id = sender.identifier?.rawValue { app?.showScope(.collection(id)) } }
    private func collectionMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        let show = NSMenuItem(title:"Show Collection",action:#selector(showCollectionItem(_:)),keyEquivalent:""); show.target = self; show.representedObject = id
        let remove = NSMenuItem(title:"Remove from Collection",action:#selector(removeCollectionItem(_:)),keyEquivalent:""); remove.target = self; remove.representedObject = id
        menu.items = [show,remove]; return menu
    }
    @objc private func showCollectionItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { app?.showScope(.collection(id)) } }
    @objc private func removeCollectionItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { app?.removeFromCollection(items,id:id) } }

    // MARK: Tags

    @objc private func searchTag(_ sender: NSButton) { app?.search(for:sender.identifier?.rawValue ?? sender.title) }
    @objc private func randomColor() { app?.searchRandomColor() }
    @objc private func acceptSuggestion(_ sender: NSButton) { if let tag = sender.identifier?.rawValue { app?.addTags([tag],to:items) } }
    @objc private func commitTag() {
        let new = Tags.parse(addTag.stringValue)
        guard !new.isEmpty else { return }
        addTag.stringValue = ""; app?.addTags(new,to:items)
    }
    private func tagMenu(_ tag: String) -> NSMenu {
        let menu = NSMenu()
        let search = NSMenuItem(title:"Show Items Tagged “\(tag)”",action:#selector(searchTagItem(_:)),keyEquivalent:""); search.target = self; search.representedObject = tag
        let remove = NSMenuItem(title:"Remove Tag",action:#selector(removeTagItem(_:)),keyEquivalent:""); remove.target = self; remove.representedObject = tag
        menu.items = [search,remove]; return menu
    }
    @objc private func searchTagItem(_ sender: NSMenuItem) { if let tag = sender.representedObject as? String { app?.search(for:tag) } }
    @objc private func removeTagItem(_ sender: NSMenuItem) { if let tag = sender.representedObject as? String { app?.removeTags([tag],from:items) } }

    // MARK: Actions

    @objc private func toggleLike() { app?.setLiked(items,!items.allSatisfy(\.liked)) }
    @objc private func openOriginal() { if let item { app?.open(item) } }
    @objc private func showInFinder() { app?.reveal(items) }
    @objc private func moveToTrash() { app?.remove(items) }
    @objc private func openSource() {
        guard let url = URL(string:source.stringValue.trimmingCharacters(in:.whitespaces)), url.scheme?.hasPrefix("http") == true else { return }
        NSWorkspace.shared.open(url)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, !items.isEmpty else { return }
        if items.count > 1 {
            if field === note {
                let shared = items.allSatisfy { $0.note == items[0].note } ? items[0].note : ""
                if note.stringValue != shared { app?.setNote(note.stringValue,for:items) }
            } else if field === author {
                let shared = items.allSatisfy { $0.author == items[0].author } ? items[0].author : ""
                let value = author.stringValue.trimmingCharacters(in:.whitespaces)
                if value != shared { app?.setAuthor(value,for:items) }
            } else if field === source {
                let editable = items.filter { $0.kind != "link" }
                let shared = editable.allSatisfy { $0.source == editable.first?.source } ? editable.first?.source ?? "" : ""
                var value = source.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                if !value.isEmpty, !value.contains("://"), value.contains(".") { value = "https://" + value; source.stringValue = value }
                if value != shared, !editable.isEmpty { app?.setSource(value,for:editable) }
            }
            return
        }
        guard let item else { return }
        if field === author, author.stringValue.trimmingCharacters(in:.whitespaces) != item.author { app?.setAuthor(author.stringValue,for:item) }
        if field === source, item.kind != "link" {
            var value = source.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if !value.isEmpty, !value.contains("://"), value.contains(".") { value = "https://" + value; source.stringValue = value }
            if value != item.source { app?.setSource(value,for:item) }
            visit.isHidden = !value.hasPrefix("http")
        }
        if field === title {
            let value = title.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if value.isEmpty { title.stringValue = item.title } else if value != item.title { app?.setTitle(value,for:item) }
        } else if field === note, note.stringValue != item.note { app?.setNote(note.stringValue,for:item) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === note, selector == #selector(NSResponder.insertNewline(_:)) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { app?.window.makeFirstResponder(app?.grid); return true }
        return false
    }
}

final class TagFlowView: NSView {
    private var buttons: [NSButton] = []
    private var desiredHeight: CGFloat = 1
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:desiredHeight) }
    func setTags(_ values: [String], ids: [String]? = nil, target: AnyObject, action: Selector, menu: ((String) -> NSMenu?)? = nil) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = values.enumerated().map { index, text in
            let id = ids?[index] ?? text
            let button = TagButton(title:text,target:target,action:action); button.identifier = .init(id)
            button.bezelStyle = .inline; button.font = .systemFont(ofSize:12); button.isBordered = false
            button.menuProvider = menu.map { provider in { provider(id) } }
            addSubview(button); return button
        }
        needsLayout = true; layoutTags()
    }
    override func layout() { super.layout(); layoutTags() }
    private func layoutTags() {
        let width = max(100,bounds.width > 0 ? bounds.width : 236)
        var x: CGFloat = 0, y: CGFloat = 0
        for button in buttons {
            let w = min(width,button.intrinsicContentSize.width + 16)
            if x > 0 && x+w > width { x = 0; y += 28 }
            button.frame = NSRect(x:x,y:y,width:w,height:22); x += w+6
        }
        let h: CGFloat = buttons.isEmpty ? 1 : y+22
        if desiredHeight != h { desiredHeight = h; invalidateIntrinsicContentSize() }
    }
}

final class InspectorDocument: NSView { override var isFlipped: Bool { true } }

final class TagButton: NSButton {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(cell?.isHighlighted == true ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:bounds.height/2,yRadius:bounds.height/2).fill()
        let text = NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:Theme.ink])
        let size = text.size()
        text.draw(in:NSRect(x:max(8,(bounds.width-size.width)/2),y:(bounds.height-size.height)/2,width:min(size.width,bounds.width-16),height:size.height))
    }
}

/// Round color swatches; click one to find items with that color.
final class SwatchRow: NSView {
    var colors: [String] = [] { didSet { rebuild() } }
    var pick: ((String) -> Void)?
    var menuProvider: ((String) -> NSMenu?)?
    private var buttons: [NSButton] = []
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:colors.isEmpty ? 1 : 26) }
    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = colors.compactMap { hex in
            guard let value = Theme.rgb(hex) else { return nil }
            let button = SwatchButton(color:Theme.color(value),hex:hex)
            button.target = self; button.action = #selector(chosen(_:)); button.toolTip = hex.uppercased()
            button.menuProvider = { [weak self] in self?.menuProvider?(hex) }
            addSubview(button); return button
        }
        for (index,button) in buttons.enumerated() { button.frame = NSRect(x:CGFloat(index)*32,y:0,width:26,height:26) }
        invalidateIntrinsicContentSize()
    }
    @objc private func chosen(_ sender: SwatchButton) { pick?(sender.hex) }
}

final class SwatchButton: NSButton {
    let color: NSColor
    let hex: String
    var menuProvider: (() -> NSMenu?)?
    init(color: NSColor, hex: String) {
        self.color = color; self.hex = hex
        super.init(frame:.zero); isBordered = false; title = ""; setAccessibilityLabel("Color \(hex.uppercased())")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn:bounds.insetBy(dx:1,dy:1))
        color.setFill(); circle.fill()
        NSColor.labelColor.withAlphaComponent(cell?.isHighlighted == true ? 0.5 : 0.15).setStroke(); circle.lineWidth = 1; circle.stroke()
    }
}
