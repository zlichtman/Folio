import AppKit
import ShelfCore

/// Automatic tagging: classification and text recognition on this Mac, one image at a time in the background.
extension AppController {
    func setAutomaticTagging(_ on: Bool) {
        UserDefaults.standard.set(on,forKey:"automaticTagging")
        if on { scheduleClassification() } else { classifierJob?.cancel(); setActivity(nil) }
    }
    @objc func tagAllImages() { scheduleClassification(force:true) }
    /// The quiet line at the bottom of the sidebar; nil hides it.
    func setActivity(_ text: String?) { activity.stringValue = text ?? ""; activity.isHidden = text == nil }
    func scheduleClassification(force: Bool = false) {
        if argument("--analysis-report") != nil { fputs("Tagging enabled: \(autoTagsEnabled)\n",stderr) }
        guard force || autoTagsEnabled else { return }
        if let current = classifierJob, !current.isFinished, !current.isCancelled {
            classificationRequestedAgain = true; return
        }
        let job = BlockOperation(); classifierJob = job
        job.completionBlock = { [weak self, weak job] in
            DispatchQueue.main.async {
                guard let self, let job, !job.isCancelled, self.classificationRequestedAgain else { return }
                self.classificationRequestedAgain = false; self.scheduleClassification()
            }
        }
        job.addExecutionBlock { [weak self, weak job] in
            guard let self, let job else { return }
            do {
                let signatures = try self.database.analysisSignatures()
                // Pictures, and the frame or preview of videos, GIFs and links: tags, colors and text for all of them.
                let candidates = try self.database.items().filter(\.hasLook)
                let pending = candidates.filter { force || signatures[$0.id] != ImageClassifier.fingerprint($0.path) }
                if argument("--analysis-report") != nil { fputs("Pending images: \(pending.count)\n",stderr) }
                guard !pending.isEmpty else {
                    DispatchQueue.main.async { if !job.isCancelled { self.setActivity(nil) } }
                    self.backfillFeaturePrints(job); self.describePictures(job)
                    self.finishClassificationDiagnostic(processed:0,failed:0); return
                }
                var completed = 0, failed = 0
                for item in pending {
                    if job.isCancelled { break }
                    do {
                        try autoreleasepool {
                            if argument("--analysis-report") != nil { fputs("Analyzing image \(completed+1)\n",stderr) }
                            let signature = ImageClassifier.fingerprint(item.path)
                            let result = try self.classifier.analyze(url:URL(fileURLWithPath:item.path),includeOCR:true)
                            if argument("--analysis-report") != nil { fputs("Classification and OCR done\n",stderr) }
                            if !job.isCancelled { try self.database.saveAnalysis(id:item.id,signature:signature,value:result,dimensions:item.kind == "image" ? MediaFiles.dimensions(URL(fileURLWithPath:item.path)) : CGSize(width:item.width,height:item.height),applyTags:true) }
                        }
                    } catch { failed += 1 }
                    completed += 1; let progress = completed
                    DispatchQueue.main.async {
                        guard !job.isCancelled else { return }
                        self.setActivity(progress == pending.count ? nil : "Sorting images · \(progress) of \(pending.count)")
                        if progress % 8 == 0 || progress == pending.count { self.preserveNextLoad = true; self.reload() }
                    }
                }
                self.backfillFeaturePrints(job); self.describePictures(job)
                if !job.isCancelled { self.finishClassificationDiagnostic(processed:completed,failed:failed) }
            } catch { DispatchQueue.main.async { self.setActivity(nil) } }
        }
        classificationQueue.addOperation(job)
    }
    func finishClassificationDiagnostic(processed: Int, failed: Int) {
        guard let output = argument("--analysis-report") else { return }
        do {
            let items = try database.items()
            let values: [[String:Any]] = try items.map { item in
                let analysis = try database.analysis(id:item.id)
                return ["title":item.title,"tags":item.tags + item.autoTags,"hasAnalysis":analysis != nil,"automaticTagsSearchable":try (analysis?.automaticTags ?? []).allSatisfy { try database.items(query:$0).contains(where:{$0.id == item.id}) },"ocrCharacters":try database.item(id:item.id)?.ocr.count ?? 0,"width":item.width,"height":item.height]
            }
            let result: [String:Any] = ["app":"Folio","version":AppIdentity.version,"processed":processed,"failed":failed,"items":values,"scope":"Real app import, local classification, persisted tags, and FTS queries. No mocked model outputs."]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                if argument("--screenshot") != nil { self.startBenchmark(to:URL(fileURLWithPath:output+".grid.json")) }
                else if args.contains("--quit-after-analysis") { NSApp.terminate(nil) }
            }
        } catch { DispatchQueue.main.async { self.showError(error) } }
    }
    @objc func indexOCR() {
        let items = grid.items.filter { $0.kind == "image" && !$0.hasText }
        guard !items.isEmpty else { notify("Text in these images is already indexed"); return }
        setActivity("Reading text · 0 of \(items.count)")
        for (index,item) in items.enumerated() {
            ocrQueue.addOperation { [weak self] in
                guard let self else { return }
                let text = (try? MediaFiles.readText(url:URL(fileURLWithPath:item.path))) ?? ""
                try? self.database.updateOCR(id:item.id,text:text)
                if index % 10 == 0 || index == items.count - 1 {
                    DispatchQueue.main.async {
                        self.setActivity(index == items.count - 1 ? nil : "Reading text · \(index+1) of \(items.count)")
                        if index == items.count - 1 { self.loadItems() }
                    }
                }
            }
        }
    }
}
