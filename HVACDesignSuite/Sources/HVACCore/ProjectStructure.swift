import Foundation

// MARK: - Customer

/// Who the job is for and where it is.
///
/// Carried on the document and printed at the head of the report. A load calculation that
/// cannot be tied to an address is not much use six months later, and a permit office
/// wants to see the job it belongs to.
public struct CustomerInformation: Codable, Sendable, Equatable {
    public var customerName: String
    public var jobNumber: String
    public var streetAddress: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var phone: String
    public var email: String
    public var preparedBy: String
    public var contractorLicense: String
    public var notes: String

    public init(customerName: String = "", jobNumber: String = "",
                streetAddress: String = "", city: String = "", state: String = "NC",
                postalCode: String = "", phone: String = "", email: String = "",
                preparedBy: String = "", contractorLicense: String = "",
                notes: String = "") {
        self.customerName = customerName; self.jobNumber = jobNumber
        self.streetAddress = streetAddress; self.city = city; self.state = state
        self.postalCode = postalCode; self.phone = phone; self.email = email
        self.preparedBy = preparedBy; self.contractorLicense = contractorLicense
        self.notes = notes
    }

    /// Single-line address for a report header. Empty parts are dropped rather than
    /// leaving stray commas.
    public var addressLine: String {
        let locality = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        let tail = [locality, postalCode].filter { !$0.isEmpty }.joined(separator: " ")
        return [streetAddress, tail].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public var hasAnyDetail: Bool {
        !(customerName.isEmpty && addressLine.isEmpty && jobNumber.isEmpty
          && phone.isEmpty && email.isEmpty && preparedBy.isEmpty)
    }
}

// MARK: - System

/// One piece of equipment and the zones it serves.
///
/// A house is not always one system. A two-storey with a finished basement is routinely
/// two or three, and each carries its own load, its own Manual S check, its own airflow
/// and its own duct tree. Modelling that as a single system and dividing afterwards gets
/// the equipment selection wrong, because the sensible/latent split of the upstairs is
/// not the split of the whole house.
public struct HVACSystem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var equipment: EquipmentSpec
    public var staticPressureBudget: StaticPressureBudget
    /// Supply-air temperature difference used to convert sensible load to airflow, °F.
    public var supplyAirDeltaTF: Double
    public var ductRuns: [DuctRun]
    /// Zones this system conditions. A zone served by no system is reported, not ignored.
    public var zoneIDs: [UUID]

    public init(id: UUID = UUID(), name: String = "System 1",
                equipment: EquipmentSpec = EquipmentSpec(),
                staticPressureBudget: StaticPressureBudget = .typical,
                supplyAirDeltaTF: Double = 20,
                ductRuns: [DuctRun] = [], zoneIDs: [UUID] = []) {
        self.id = id; self.name = name; self.equipment = equipment
        self.staticPressureBudget = staticPressureBudget
        self.supplyAirDeltaTF = supplyAirDeltaTF
        self.ductRuns = ductRuns; self.zoneIDs = zoneIDs
    }
}

// MARK: - Custom materials

/// Materials and assemblies an engineer adds to a particular job.
///
/// The shipped library covers what turns up most, not everything that exists. A job with
/// a straw-bale wall, a reflective radiant barrier, or a manufacturer's proprietary panel
/// needs its own entries, and they belong to the job rather than to the application, so
/// they travel in the saved file and cannot be lost when the app is reinstalled.
public struct CustomLibrary: Codable, Sendable, Equatable {
    public var materials: [Material]
    public var assemblies: [Assembly]

    public init(materials: [Material] = [], assemblies: [Assembly] = []) {
        self.materials = materials
        self.assemblies = assemblies
    }

    public var isEmpty: Bool { materials.isEmpty && assemblies.isEmpty }

    /// Every material available on this job, custom entries first so a project override
    /// of a shipped name wins.
    public func allMaterials() -> [Material] {
        var seen = Set<String>()
        return (materials + Material.library).filter { seen.insert($0.name).inserted }
    }

    public func assemblies(for category: SurfaceCategory) -> [Assembly] {
        var seen = Set<String>()
        return (assemblies + AssemblyLibrary.standard)
            .filter { $0.category == category }
            .filter { seen.insert($0.name).inserted }
    }
}
