import Foundation

/// Deterministic shipped defaults. Existing ledger icons, colors and pins are not rewritten.
enum CategoryCatalogAppearance {
    struct Style: Equatable {
        let symbol: String
        let color: String
        let pinned: Bool
    }

    private static let roots: [String: (String, String)] = [
        "expense.dining": ("fork.knife", "orange"), "expense.groceries": ("basket", "green"),
        "expense.transportation": ("bus", "blue"), "expense.vehicle": ("car", "blue"),
        "expense.home": ("house", "teal"), "expense.household": ("sofa", "teal"),
        "expense.clothing": ("tshirt", "purple"), "expense.personal-care": ("comb", "purple"),
        "expense.digital-services": ("wifi", "blue"), "expense.devices": ("desktopcomputer", "blue"),
        "expense.health": ("cross.case", "green"), "expense.education": ("graduationcap", "blue"),
        "expense.childcare": ("figure.2.and.child.holdinghands", "orange"),
        "expense.entertainment": ("gamecontroller", "purple"), "expense.hobbies": ("figure.run", "green"),
        "expense.travel": ("suitcase.rolling", "teal"), "expense.gifts": ("gift", "orange"),
        "expense.pets": ("pawprint", "orange"), "expense.insurance": ("shield.checkered", "green"),
        "expense.other": ("doc.text", "teal"), "income.work": ("banknote", "green"),
        "income.side-work": ("briefcase", "teal"), "income.investment": ("chart.line.uptrend.xyaxis", "green"),
        "income.rental": ("building.2", "blue"), "income.gifts": ("giftcard", "orange"),
        "income.other": ("plus.circle", "green")
    ]

    private static let leaves: [String: String] = [
        "expense.dining.breakfast": "sunrise", "expense.dining.coffee": "cup.and.saucer",
        "expense.dining.tea-drink": "takeoutbag.and.cup.and.straw", "expense.dining.beverages": "cup.and.saucer",
        "expense.dining.snacks": "birthday.cake", "expense.dining.fruit": "basket", "expense.dining.alcohol": "wineglass",
        "expense.groceries.vegetables": "carrot", "expense.transportation.metro": "tram",
        "expense.transportation.taxi": "car", "expense.transportation.bike": "bicycle",
        "expense.transportation.rail": "tram", "expense.transportation.flight": "airplane",
        "expense.vehicle.fuel": "fuelpump", "expense.vehicle.charging": "bolt.house",
        "expense.vehicle.parking": "parkingsign.circle", "expense.vehicle.toll": "road.lanes",
        "expense.vehicle.maintenance": "wrench.and.screwdriver", "expense.vehicle.insurance": "shield.checkered",
        "expense.home.property": "building.2", "expense.home.electricity": "bolt.house",
        "expense.home.repair": "wrench.and.screwdriver", "expense.home.moving": "shippingbox",
        "expense.household.appliances": "washer", "expense.household.appliance-service": "wrench.and.screwdriver",
        "expense.household.tools": "wrench.and.screwdriver", "expense.household.gardening": "leaf",
        "expense.clothing.bags": "bag", "expense.clothing.laundry": "washer",
        "expense.personal-care.haircut": "scissors", "expense.personal-care.hair-treatment": "comb",
        "expense.digital-services.phone-plan": "smartphone", "expense.digital-services.media": "rectangle.stack.badge.play",
        "expense.digital-services.reading": "book", "expense.digital-services.software": "desktopcomputer",
        "expense.devices.phone": "smartphone", "expense.devices.computer": "laptopcomputer",
        "expense.devices.audio": "headphones", "expense.devices.repair": "wrench.and.screwdriver",
        "expense.health.medicine": "pills", "expense.health.checkup": "heart.text.clipboard",
        "expense.health.wellness": "heart", "expense.education.books": "book",
        "expense.education.stationery": "pencil.and.ruler", "expense.education.learning-device": "desktopcomputer",
        "expense.entertainment.movie": "film", "expense.entertainment.show": "theatermasks",
        "expense.entertainment.karaoke-bar": "music.note", "expense.entertainment.exhibition": "paintpalette",
        "expense.hobbies.gym": "dumbbell", "expense.hobbies.venue": "sportscourt",
        "expense.hobbies.camping": "house.lodge", "expense.hobbies.camera": "camera",
        "expense.hobbies.photo-service": "camera", "expense.hobbies.music-art": "paintpalette",
        "expense.travel.lodging": "bed.double", "expense.travel.tickets": "ticket",
        "expense.travel.guide": "map", "expense.travel.visa": "doc.text",
        "expense.gifts.red-envelope": "envelope", "expense.gifts.parents": "person.2",
        "expense.gifts.charity": "heart", "expense.pets.medical": "cross.case",
        "expense.pets.grooming": "scissors", "expense.other.fees": "creditcard",
        "expense.other.interest": "percent", "expense.other.postage": "shippingbox",
        "income.work.overtime": "clock.arrow.circlepath", "income.side-work.royalties": "book",
        "income.investment.deposit-interest": "percent", "income.investment.product-interest": "percent",
        "income.investment.dividend": "chart.pie", "income.rental.parking": "parkingsign.circle",
        "income.gifts.red-envelope": "envelope", "income.other.award": "graduationcap"
    ]

    static func style(for definition: CategoryCatalog.Definition) -> Style {
        let root = roots[definition.parentSemanticKey ?? definition.semanticKey]
            ?? (CategoryIconLibrary.fallback, definition.kind == .expense ? "teal" : "green")
        let pinned: Set<String> = ["expense.dining.breakfast", "expense.dining.lunch", "expense.dining.dinner",
                                  "expense.transportation.metro", "expense.transportation.taxi", "income.work.salary"]
        return Style(symbol: leaves[definition.semanticKey] ?? root.0, color: root.1,
                     pinned: pinned.contains(definition.semanticKey))
    }
}
