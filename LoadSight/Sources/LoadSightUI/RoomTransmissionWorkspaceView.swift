import SwiftUI
import LoadSightKit

private struct ScalarDraft: Equatable {
    var value = "", source = ""
    var classification = AirInputClassification.userProvided
    func input(_ label: String) throws -> SourcedEngineeringValue {
        guard let numeric = Double(value), numeric.isFinite else { throw LoadSightError.invalid("Enter a numeric \(label).") }
        return .init(value:numeric,source:source,classification:classification)
    }
}
private struct OpeningDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var area = ScalarDraft()
    var hasRating = false
    var rating = ScalarDraft()
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.area == rhs.area && lhs.hasRating == rhs.hasRating && lhs.rating == rhs.rating
    }
}
private struct SurfaceDraft: Identifiable, Equatable {
    let id = UUID()
    var name = "", assemblyID = ""
    var gross = ScalarDraft(), adjacent = ScalarDraft()
    var openings: [OpeningDraft] = []
    var confirmsNoOpenings = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.assemblyID == rhs.assemblyID && lhs.gross == rhs.gross && lhs.adjacent == rhs.adjacent && lhs.openings == rhs.openings && lhs.confirmsNoOpenings == rhs.confirmsNoOpenings
    }
    func input() throws -> RoomEnvelopeSurface {
        try require(!openings.isEmpty || confirmsNoOpenings,"Confirm no openings or enter opening areas for \(name).")
        return try .init(name:name,assemblyID:assemblyID,grossAreaSF:gross.input("gross area"),openings:openings.map { try .init(name:$0.name,areaSF:$0.area.input("opening area"),wholeProductU:$0.hasRating ? $0.rating.input("whole-product U-factor") : nil) },adjacentDesignF:adjacent.input("adjacent design temperature"))
    }
}
private struct RoomDraft: Equatable {
    var name = "", author = "", source = ""
    var indoor = ScalarDraft()
    var surfaces = [SurfaceDraft()]
    var reason = ""
}

struct RoomTransmissionWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var draft = RoomDraft()
    @State private var baseline = RoomDraft()
    @State private var result: RoomTransmissionResult?
    @State private var error: String?
    @State private var saved: String?
    @State private var editingID: String?
    @State private var expectedFingerprint = ""
    @State private var pendingRoom: RoomTransmissionRecord?
    @State private var replaceDraft = false
    var body: some View {
        Form {
            Section("Room envelope transmission") {
                Text("Calculate steady-state heat transfer through above-grade opaque surfaces and rated openings. Save the required envelope assemblies first. Temperatures must describe the same design case.").foregroundStyle(.secondary)
                if editingID != nil {
                    Text("Revising saved case. Prior inputs remain in history.").font(.caption)
                    TextField("Revision reason",text:$draft.reason,axis:.vertical).accessibilityLabel("Revision reason")
                }
                Button("Start a new case") {
                    if draft != baseline { pendingRoom = nil; replaceDraft = true }
                    else { resetForm() }
                }
                TextField("Room / design-case name",text:$draft.name)
                TextField("Recorded by",text:$draft.author)
                TextField("Room drawing and design-case source",text:$draft.source,axis:.vertical).accessibilityLabel("Room drawing and design-case source")
                ScalarInputEditor(label:"Indoor design temperature (°F)",draft:$draft.indoor)
            }
            ForEach($draft.surfaces) { $surface in
                Section("Opaque surface") {
                    SurfaceInputEditor(draft:$surface,assemblies:(try? document.project.envelopeAssemblies()) ?? [])
                    Button("Remove surface",role:.destructive) { draft.surfaces.removeAll { $0.id == surface.id } }
                }
            }
            Section {
                Button("Add opaque surface") { draft.surfaces.append(SurfaceDraft()) }
                Button("Review room transmission") {
                    do {
                        var candidate = document.project
                        let id = try save(to:&candidate)
                        result = try candidate.roomTransmissions().first(where:{$0.id == id})?.calculate(assemblies:candidate.envelopeAssemblies())
                        error = nil; saved = nil
                    } catch { result = nil; self.error = error.localizedDescription }
                }
                if let result { RoomTransmissionResultRows(result:result) }
                Button(editingID == nil ? "Save room transmission" : "Save revision") {
                    do {
                        let id = try save(to:&document.project)
                        editingID = id; expectedFingerprint = try document.project.roomTransmissionEditFingerprint(id:id)
                        baseline = draft
                        error = nil; saved = "Room transmission saved. Project QA reopened."
                    }
                    catch { self.error = error.localizedDescription; saved = nil }
                }
                if let saved { Text(saved).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Saved room transmission cases") {
                switch records {
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                case .success(let rooms):
                    if rooms.isEmpty { Text("No room transmission cases saved.").foregroundStyle(.secondary) }
                    ForEach(rooms) { room in
                        DisclosureGroup(room.name) {
                            Button("Revise this case") {
                                if draft != baseline { pendingRoom = room; replaceDraft = true }
                                else { beginRevision(room) }
                            }
                            Text("\(room.author) · \(room.recordedAt)")
                            Text(room.source).textSelection(.enabled)
                            Text("Indoor \(room.indoorDesignF.value) °F · \(room.indoorDesignF.classification.rawValue): \(room.indoorDesignF.source)")
                            ForEach(Array(room.surfaces.enumerated()),id:\.offset) { _, surface in
                                DisclosureGroup(surface.name + " inputs") {
                                    Text("Assembly: \(surface.assemblyID)")
                                    Text("Gross area \(surface.grossAreaSF.value) ft² · \(surface.grossAreaSF.classification.rawValue): \(surface.grossAreaSF.source)")
                                    Text("Adjacent \(surface.adjacentDesignF.value) °F · \(surface.adjacentDesignF.classification.rawValue): \(surface.adjacentDesignF.source)")
                                    if surface.openings.isEmpty { Text("No openings declared.") }
                                    ForEach(Array(surface.openings.enumerated()),id:\.offset) { _, opening in
                                        Text("\(opening.name): \(opening.areaSF.value) ft² · \(opening.areaSF.classification.rawValue): \(opening.areaSF.source)")
                                        if let rating = opening.wholeProductU {
                                            Text("Whole-product U \(rating.value) Btuh/(ft²·°F) · \(rating.classification.rawValue): \(rating.source)")
                                        } else { Text("Whole-product U missing; opening transmission unknown.").foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            if let assemblies = try? document.project.envelopeAssemblies(), let result = try? room.calculate(assemblies:assemblies) { RoomTransmissionResultRows(result:result) }
                            ForEach(room.assumptionsLog,id:\.self) { Text($0).font(.caption) }
                            if let history = try? document.project.roomTransmissionHistory() {
                                ForEach(history.filter { $0.roomID == room.id }) { revision in
                                    DisclosureGroup("Revision: " + revision.recordedAt) {
                                        Text(revision.author + " · " + revision.reason)
                                        RoomRevisionSnapshotView(label:"Before",snapshot:revision.before,result:try? revision.result(before:true))
                                        RoomRevisionSnapshotView(label:"After",snapshot:revision.after,result:try? revision.result(before:false))
                                        Text("Historical results use the assembly inputs saved with this revision.").font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.formStyle(.grouped)
        .onChange(of:draft) { _, _ in result = nil; error = nil; saved = nil }
        .onChange(of:document.project.root) { _, _ in result = nil }
        .confirmationDialog("Replace the unsaved form inputs?",isPresented:$replaceDraft,titleVisibility:.visible) {
            Button("Discard form changes",role:.destructive) {
                if let pendingRoom { beginRevision(pendingRoom) }
                else { resetForm() }
                pendingRoom = nil
            }
            Button("Keep editing",role:.cancel) { pendingRoom = nil }
        }
    }
    private var records: Result<[RoomTransmissionRecord],Error> { Result { try document.project.roomTransmissions() } }
    private func save(to project: inout ProjectDocument) throws -> String {
        if let editingID {
            return try project.reviseRoomTransmission(id:editingID,expectedFingerprint:expectedFingerprint,reason:draft.reason,name:draft.name,author:draft.author,source:draft.source,indoorDesignF:draft.indoor.input("indoor design temperature"),surfaces:draft.surfaces.map { try $0.input() })
        }
        return try project.saveRoomTransmission(name:draft.name,author:draft.author,source:draft.source,indoorDesignF:draft.indoor.input("indoor design temperature"),surfaces:draft.surfaces.map { try $0.input() })
    }
    private func resetForm() {
        draft = RoomDraft(); baseline = draft; editingID = nil; expectedFingerprint = ""; result = nil; error = nil; saved = nil
    }
    private func beginRevision(_ room: RoomTransmissionRecord) {
        do {
            let requestedID = room.id
            guard let room = try document.project.roomTransmissions().first(where:{$0.id == requestedID}) else { throw LoadSightError.invalid("Room case no longer exists.") }
            let fingerprint = try document.project.roomTransmissionEditFingerprint(id:room.id)
            draft = RoomDraft(name:room.name,author:"",source:room.source,indoor:ScalarDraft(room.indoorDesignF),surfaces:room.surfaces.map { surface in
                SurfaceDraft(name:surface.name,assemblyID:surface.assemblyID,gross:ScalarDraft(surface.grossAreaSF),adjacent:ScalarDraft(surface.adjacentDesignF),openings:surface.openings.map { opening in
                    OpeningDraft(name:opening.name,area:ScalarDraft(opening.areaSF),hasRating:opening.wholeProductU != nil,rating:opening.wholeProductU.map(ScalarDraft.init) ?? ScalarDraft())
                },confirmsNoOpenings:surface.openings.isEmpty)
            })
            baseline = draft
            editingID = room.id; expectedFingerprint = fingerprint; result = nil; error = nil; saved = nil
        } catch { self.error = error.localizedDescription }
    }
}
private struct ScalarInputEditor: View {
    let label: String
    @Binding var draft: ScalarDraft
    var body: some View {
        LabeledContent(label) { TextField(label,text:$draft.value).multilineTextAlignment(.trailing) }
        TextField(label + " source",text:$draft.source,axis:.vertical).accessibilityLabel(label + " source")
        Picker(label + " classification",selection:$draft.classification) {
            ForEach(AirInputClassification.allCases,id:\.self) { Text($0.rawValue).tag($0) }
        }
    }
}
private struct SurfaceInputEditor: View {
    @Binding var draft: SurfaceDraft
    let assemblies: [EnvelopeAssemblyRecord]
    var body: some View {
        TextField("Surface name / drawing location",text:$draft.name)
        Picker("Assembly",selection:$draft.assemblyID) {
            Text("Choose a saved assembly").tag("")
            ForEach(assemblies) { Text($0.name).tag($0.id) }
        }
        ScalarInputEditor(label:"Gross area including openings (ft²)",draft:$draft.gross)
        ScalarInputEditor(label:"Adjacent design temperature (°F)",draft:$draft.adjacent)
        ForEach($draft.openings) { $opening in
            DisclosureGroup(opening.name.isEmpty ? "New opening deduction" : opening.name) {
                TextField("Opening name",text:$opening.name)
                ScalarInputEditor(label:"Full product opening area (ft²)",draft:$opening.area)
                Toggle("Whole-product U-factor available",isOn:$opening.hasRating)
                if opening.hasRating {
                    ScalarInputEditor(label:"Whole-product U (Btuh/ft²·°F)",draft:$opening.rating)
                    Text("Use the complete product rating, including frame. Cite the exact product/configuration and rating basis. Center-of-glass or door-slab values do not describe the whole opening.").font(.caption)
                } else { Text("This opening remains unrated. Combined envelope subtotals will be withheld.").font(.caption) }
                Button("Remove opening",role:.destructive) { draft.openings.removeAll { $0.id == opening.id } }
            }
        }
        Button("Add opening deduction") { draft.openings.append(OpeningDraft()); draft.confirmsNoOpenings = false }
        if draft.openings.isEmpty { Toggle("This surface has no openings",isOn:$draft.confirmsNoOpenings) }
        Text("Openings are deducted from opaque area and calculated separately when rated. Do not enter slab or ground-coupled surfaces.").font(.caption)
    }
}
private struct RoomTransmissionResultRows: View {
    let result: RoomTransmissionResult
    var body: some View {
        LabeledContent("Outward opaque loss (Btuh)",value:String(format:"%.2f",result.outwardLossBtuh))
        LabeledContent("Inward opaque gain (Btuh)",value:String(format:"%.2f",result.inwardGainBtuh))
        LabeledContent("Net outward balance (Btuh)",value:String(format:"%.2f",result.netOutwardBtuh))
        ForEach(Array(result.surfaces.enumerated()),id:\.offset) { _, surface in
            DisclosureGroup(surface.name + " calculation") {
                Text("Net area \(surface.netOpaqueAreaSF) ft² · U \(surface.uFactor) Btuh/(ft²·°F)")
                ForEach(Array(surface.traces.enumerated()),id:\.offset) { _, trace in
                    Text("\(trace.equation)\n\(trace.substitution) = \(trace.value) \(trace.unit)").font(.caption).textSelection(.enabled)
                }
            }
        }
        DisclosureGroup("Room summation traces") {
            ForEach(Array(result.traces.enumerated()),id:\.offset) { _, trace in
                Text("\(trace.equation)\n\(trace.substitution) = \(trace.value) \(trace.unit)").font(.caption).textSelection(.enabled)
            }
        }
        if let openings = result.openingTransmission { OpeningTransmissionResultRows(result:openings) }
        Text("Partial transmission only. Unmodeled components are not zero: " + result.excludedComponents.joined(separator:"; ") + ".").font(.caption).foregroundStyle(.secondary)
    }
}

private struct OpeningTransmissionResultRows: View {
    let result: OpeningTransmissionSummary
    var body: some View {
        LabeledContent("Known opening loss (Btuh)",value:String(format:"%.2f",result.knownOpeningLossBtuh))
        LabeledContent("Known opening gain (Btuh)",value:String(format:"%.2f",result.knownOpeningGainBtuh))
        if result.openings.isEmpty { Text("No openings declared in this case.").font(.caption) }
        ForEach(Array(result.openings.enumerated()),id:\.offset) { _, opening in
            DisclosureGroup(opening.surfaceName + " / " + opening.openingName) {
                if let trace = opening.trace {
                    Text("\(trace.equation)\n\(trace.substitution) = \(trace.value) \(trace.unit)").font(.caption).textSelection(.enabled)
                    ForEach(trace.assumptions,id:\.self) { Text($0).font(.caption) }
                } else { Text("Missing whole-product U-factor. Transmission remains unknown.").foregroundStyle(.secondary) }
            }
        }
        if let loss = result.combinedEnvelopeLossBtuh, let gain = result.combinedEnvelopeGainBtuh, let net = result.combinedEnvelopeNetOutwardBtuh {
            LabeledContent("Entered envelope loss (Btuh)",value:String(format:"%.2f",loss))
            LabeledContent("Entered envelope gain (Btuh)",value:String(format:"%.2f",gain))
            LabeledContent("Entered envelope net outward (Btuh)",value:String(format:"%.2f",net))
            Text("All listed openings are rated. This subtotal covers the entered surface ledger; it is not a complete room load.").font(.caption)
        } else { Text("Combined envelope subtotal unavailable: one or more opening U-factors are missing.").foregroundStyle(.secondary) }
        DisclosureGroup("Opening and envelope summation traces") {
            ForEach(Array(result.traces.enumerated()),id:\.offset) { _, trace in
                Text("\(trace.equation)\n\(trace.substitution) = \(trace.value) \(trace.unit)").font(.caption).textSelection(.enabled)
            }
            ForEach(result.assumptions,id:\.self) { Text($0).font(.caption) }
        }
    }
}

private extension ScalarDraft {
    init(_ value: SourcedEngineeringValue) {
        self.init(value:String(value.value),source:value.source,classification:value.classification)
    }
}
private struct RoomRevisionSnapshotView: View {
    let label: String
    let snapshot: JSONValue
    let result: RoomTransmissionResult?
    var body: some View {
        DisclosureGroup(label + " inputs and results") {
            Text((snapshot["name"].string ?? "") + " · " + (snapshot["source"].string ?? ""))
            if let room = try? JSONDecoder().decode(RoomTransmissionRecord.self,from:JSONEncoder().encode(snapshot)) {
                Text("Indoor \(room.indoorDesignF.value) °F · \(room.indoorDesignF.classification.rawValue): \(room.indoorDesignF.source)")
                ForEach(Array(room.surfaces.enumerated()),id:\.offset) { _, surface in
                    Text("\(surface.name) · assembly \(surface.assemblyID)")
                    Text("Gross \(surface.grossAreaSF.value) ft² · \(surface.grossAreaSF.source); adjacent \(surface.adjacentDesignF.value) °F · \(surface.adjacentDesignF.source)").font(.caption)
                    ForEach(Array(surface.openings.enumerated()),id:\.offset) { _, opening in
                        Text("\(opening.name): \(opening.areaSF.value) ft² · \(opening.areaSF.source)").font(.caption)
                        if let rating = opening.wholeProductU { Text("U \(rating.value) · \(rating.classification.rawValue): \(rating.source)").font(.caption) }
                    }
                }
            }
            if let result { RoomTransmissionResultRows(result:result) }
        }
    }
}
