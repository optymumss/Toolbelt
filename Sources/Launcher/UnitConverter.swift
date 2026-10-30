import Foundation

/// Converts units typed into the launcher, such as "5 km in miles",
/// "100 f to c", "3 lb in kg" or "2 GB to MB".
enum UnitConverter {
    struct Result {
        let value: Double
        let text: String
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(-?\d+(?:[.,]\d+)?)\s*(.+?)\s+(?:in|to|into|as|=)\s+(.+?)\s*$"#,
        options: [.caseInsensitive]
    )

    static func convert(_ input: String) -> Result? {
        let range = NSRange(input.startIndex..., in: input)
        guard let match = pattern.firstMatch(in: input, range: range),
              let numberRange = Range(match.range(at: 1), in: input),
              let fromRange = Range(match.range(at: 2), in: input),
              let toRange = Range(match.range(at: 3), in: input),
              let value = Double(input[numberRange].replacingOccurrences(of: ",", with: ".")),
              let from = unit(named: String(input[fromRange])),
              let to = unit(named: String(input[toRange])),
              type(of: from) == type(of: to) else { return nil }

        let converted = Measurement(value: value, unit: from).converted(to: to).value
        guard converted.isFinite else { return nil }
        let toName = input[toRange].trimmingCharacters(in: .whitespaces)
        return Result(value: converted, text: "\(format(converted)) \(toName)")
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func unit(named raw: String) -> Dimension? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let unit = units[name] { return unit }
        if name.hasSuffix("s"), let unit = units[String(name.dropLast())] { return unit } // "miles"
        return nil
    }

    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))

    private static let units: [String: Dimension] = {
        var table: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) {
            for name in names { table[name] = unit }
        }
        // Length
        add(UnitLength.meters, "m", "meter", "metre")
        add(UnitLength.kilometers, "km", "kilometer", "kilometre")
        add(UnitLength.centimeters, "cm", "centimeter", "centimetre")
        add(UnitLength.millimeters, "mm", "millimeter", "millimetre")
        add(UnitLength.miles, "mi", "mile")
        add(UnitLength.yards, "yd", "yard")
        add(UnitLength.feet, "ft", "foot", "feet")
        add(UnitLength.inches, "in", "inch", "inches")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile")
        // Mass
        add(UnitMass.kilograms, "kg", "kilo", "kilogram")
        add(UnitMass.grams, "g", "gram")
        add(UnitMass.milligrams, "mg", "milligram")
        add(UnitMass.pounds, "lb", "lbs", "pound")
        add(UnitMass.ounces, "oz", "ounce")
        add(UnitMass.stones, "st", "stone")
        add(UnitMass.metricTons, "t", "tonne", "ton")
        // Temperature
        add(UnitTemperature.celsius, "c", "°c", "celsius", "degc")
        add(UnitTemperature.fahrenheit, "f", "°f", "fahrenheit", "degf")
        add(UnitTemperature.kelvin, "k", "kelvin")
        // Volume
        add(UnitVolume.liters, "l", "liter", "litre")
        add(UnitVolume.milliliters, "ml", "milliliter", "millilitre")
        add(UnitVolume.gallons, "gal", "gallon")
        add(UnitVolume.imperialGallons, "uk gallon", "imperial gallon")
        add(UnitVolume.fluidOunces, "floz", "fl oz", "fluid ounce")
        add(UnitVolume.cups, "cup")
        add(UnitVolume.pints, "pt", "pint")
        add(UnitVolume.imperialPints, "uk pint", "imperial pint")
        // Speed
        add(UnitSpeed.kilometersPerHour, "kph", "km/h", "kmh")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.knots, "knot", "kn")
        // Area
        add(UnitArea.squareMeters, "m2", "m²", "sq m", "square meter", "square metre")
        add(UnitArea.squareKilometers, "km2", "km²", "sq km")
        add(UnitArea.squareFeet, "ft2", "ft²", "sq ft", "square foot", "square feet")
        add(UnitArea.acres, "acre")
        add(UnitArea.hectares, "ha", "hectare")
        // Time
        add(UnitDuration.seconds, "s", "sec", "second")
        add(UnitDuration.minutes, "min", "minute")
        add(UnitDuration.hours, "h", "hr", "hour")
        add(day, "d", "day")
        add(week, "wk", "week")
        // Data
        add(UnitInformationStorage.bytes, "b", "byte")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte")
        add(UnitInformationStorage.megabytes, "mb", "megabyte")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte")
        add(UnitInformationStorage.terabytes, "tb", "terabyte")
        add(UnitInformationStorage.kibibytes, "kib")
        add(UnitInformationStorage.mebibytes, "mib")
        add(UnitInformationStorage.gibibytes, "gib")
        return table
    }()
}
