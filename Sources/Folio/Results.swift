import AppKit
import Vision
import ShelfCore

/// Views that aren't a sidebar place: search results and items that look alike. The title bar names what's shown
/// and carries a back button out of them.
extension AppController {
    /// Shows a list of items under a title, until Back, Esc or a sidebar click.
    func showResults(_ title: String, _ items: [ShelfItem]) {
        results = (title,items)
        updatingSidebar = true; sidebar.deselectAll(nil); updatingSidebar = false
        grid.select([],focus:nil); loadItems()
    }
    @objc func goBack() {
        if !viewer.isHidden { viewer.closeViewer(); return }
        if results != nil { results = nil }
        else if !search.stringValue.isEmpty { searchCleared(search.stringValue); search.stringValue = ""; searchText = "" }
        else { return }
        if let row = rows.firstIndex(where:{ $0.kind != .header && $0.scope == scope }) {
            updatingSidebar = true; sidebar.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); updatingSidebar = false
        }
        loadItems(); window.makeFirstResponder(grid)
    }
    func updateTitle(count: Int) {
        if let heading = viewer.isHidden ? nil : viewer.heading {
            titleLabel.stringValue = heading.title; countLabel.stringValue = heading.position
            backButton.isHidden = false; backButton.toolTip = "Back to \(collectionTitle) · Esc"; window.title = heading.title
            return
        }
        backButton.toolTip = "Back · Esc"
        let query = search.stringValue.trimmingCharacters(in:.whitespaces)
        let title = results?.title ?? (query.isEmpty ? collectionTitle : "Results for “\(query.trimmingCharacters(in:CharacterSet(charactersIn:"\"")))”")
        titleLabel.stringValue = title
        let exact = count - relatedCount
        countLabel.stringValue = count == 0 && query.isEmpty ? "" : (relatedCount > 0 ? "\(exact.formatted()) matching · \(relatedCount.formatted()) related" : count == 1 ? "1 item" : "\(count.formatted()) items")
            + (filter.map { " · \($0.title)" } ?? "")
        backButton.isHidden = results == nil && query.isEmpty
        window.title = title
    }
    func makeTitleBar() -> NSView {
        backButton.image = NSImage(systemSymbolName:"chevron.left",accessibilityDescription:"Back")
        backButton.bezelStyle = .accessoryBarAction; backButton.isBordered = false; backButton.target = self; backButton.action = #selector(goBack)
        backButton.toolTip = "Back · Esc"; backButton.isHidden = true
        titleLabel.font = .systemFont(ofSize:13,weight:.semibold); titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize:12); countLabel.textColor = .secondaryLabelColor
        titleLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let stack = NSStackView(views:[backButton,titleLabel,countLabel]); stack.spacing = 6; stack.alignment = .firstBaseline
        stack.setCustomSpacing(2,after:backButton)
        return stack
    }

    // MARK: Find similar

    /// Exact copies across the library, shown together with the extra copies selected; the oldest of each is kept.
    @objc func findDuplicates() {
        setActivity("Looking for copies…")
        similarityQueue.async { [weak self] in
            guard let self else { return }
            let all = (try? self.database.items()) ?? []
            let groups = Duplicates.groups(all)
            let byID = Dictionary(all.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
            let shown = groups.flatMap { $0.compactMap { byID[$0] } }, extras = groups.flatMap { $0.dropFirst().compactMap { byID[$0] } }
            DispatchQueue.main.async {
                self.setActivity(nil)
                guard !extras.isEmpty else { self.notify("No copies: every file is one of a kind"); return }
                self.afterLoad = { [weak self] in
                    self?.grid.select(Set(extras.map(\.id)),focus:extras.first?.id)
                    let noun = extras.count == 1 ? "1 extra copy" : "\(extras.count) extra copies"
                    self?.toast.show("\(noun) selected. The oldest of each stays.",action:("Move to Trash",{ [weak self] in self?.remove(extras) }))
                }
                self.showResults("Duplicates",shown)
            }
        }
    }
    /// A colour from the library itself, picked at random, searched for: a way to wander through what's there.
    @objc func searchRandomColor() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let pool = ((try? self.database.items(sort:.random(seed:Int64.random(in:1...Int64(Int32.max))),limit:60)) ?? []).filter { !$0.colors.isEmpty }
            guard let item = pool.randomElement(), let hex = (item.kind == "color" ? item.colors.first : item.colors.prefix(3).randomElement()) else {
                DispatchQueue.main.async { self.notify("Folio is still reading the colours in your pictures. Try again in a moment.") }; return
            }
            DispatchQueue.main.async { self.runSearch(hex) }
        }
    }
    @objc func findSimilar() {
        guard let item = selected, item.hasLook else { NSSound.beep(); return }
        setActivity("Finding similar images…")
        similarityQueue.async { [weak self] in
            guard let self else { return }
            var prints = self.loadedPrints()
            if prints[item.id] == nil, let data = try? VisualSimilarity.featurePrint(url:URL(fileURLWithPath:item.path)) {
                try? self.database.saveFeaturePrint(id:item.id,version:VisualSimilarity.version,data:data)
                prints[item.id] = VisualSimilarity.observation(data)
            }
            self.printCache = prints
            let nearest = VisualSimilarity.nearest(to:item.id,in:prints,limit:80)
            let found = [item] + nearest.compactMap { try? self.database.item(id:$0.id) }.filter { $0.trashed == nil }
            DispatchQueue.main.async {
                self.setActivity(nil)
                if found.count == 1 {
                    self.notify(prints.count < 2 ? "Folio is still reading your images. Try again in a moment." : "Nothing looks like this yet")
                } else {
                    self.afterLoad = { [weak self] in self?.grid.select([item.id],focus:item.id) }
                    self.showResults("Similar to “\(item.title)”",found)
                }
            }
        }
    }
    /// Every saved feature print, kept between uses. Only touch on `similarityQueue`.
    func loadedPrints() -> [String:VNFeaturePrintObservation] {
        if let printCache { return printCache }
        let prints = Dictionary(uniqueKeysWithValues:((try? database.featurePrints(version:VisualSimilarity.version)) ?? [])
            .compactMap { entry in VisualSimilarity.observation(entry.data).map { (entry.id,$0) } })
        printCache = prints
        return prints
    }
    /// The tags the user gave the items that look most like these, best first. Suggestions learnt from their own
    /// library, worked out on this Mac: a tag counts more the closer the look-alike, and needs two look-alikes
    /// agreeing unless one is a near copy.
    func tagsFromLookalikes(_ items: [ShelfItem], completion: @escaping ([String]) -> Void) {
        let targets = items.filter(\.hasLook).prefix(12).map(\.id)
        guard !targets.isEmpty else { return }
        similarityQueue.async { [weak self] in
            guard let self else { return }
            let prints = self.loadedPrints(), chosen = Set(targets)
            var votes: [String:(name: String, weight: Float, count: Int)] = [:]
            for target in targets {
                for neighbour in VisualSimilarity.nearest(to:target,in:prints,limit:12) where !chosen.contains(neighbour.id) && neighbour.distance < 0.85 {
                    guard let item = try? self.database.item(id:neighbour.id), item.trashed == nil else { continue }
                    for tag in Tags.clean(item.tags) {
                        let key = tag.lowercased(), old = votes[key]
                        votes[key] = (old?.name ?? tag,(old?.weight ?? 0) + (0.9 - neighbour.distance),(old?.count ?? 0) + 1)
                    }
                }
            }
            let picks = votes.values.filter { $0.count >= 2 || $0.weight > 0.45 }.sorted { $0.weight > $1.weight }.prefix(6).map(\.name)
            DispatchQueue.main.async { completion(Array(picks)) }
        }
    }
    /// Computes feature prints for images that don't have one, a batch at a time, in the background.
    func backfillFeaturePrints(_ job: BlockOperation) {
        while !job.isCancelled, let batch = try? database.itemsMissingFeaturePrint(version:VisualSimilarity.version,limit:50), !batch.isEmpty {
            var saved = 0
            for entry in batch where !job.isCancelled {
                autoreleasepool {
                    let data = (try? VisualSimilarity.featurePrint(url:URL(fileURLWithPath:entry.path))) ?? Data()
                    // An empty print marks a file that can't be read, so it isn't tried again on every pass.
                    try? database.saveFeaturePrint(id:entry.id,version:VisualSimilarity.version,data:data)
                    saved += 1
                }
            }
            if saved > 0 { similarityQueue.async { [weak self] in self?.printCache = nil } }
        }
    }
}
