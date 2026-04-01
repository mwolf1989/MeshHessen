import Foundation

/// NOAA solar calculator for sunrise/sunset times.
/// Used to classify telemetry data as day or night.
struct SunriseSunsetService {

    /// Returns (sunrise, sunset) as hours since midnight (local time) for the given date and coordinates.
    /// Returns (6.0, 22.0) as fallback for invalid coordinates or polar regions.
    static func getSunriseSunset(date: Date, latitude: Double, longitude: Double) -> (sunrise: Double, sunset: Double) {
        guard abs(latitude) > 0.001 || abs(longitude) > 0.001 else {
            return (6.0, 22.0)
        }

        let calendar = Calendar.current
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let year = Double(calendar.component(.year, from: date))

        // Julian day
        let a = floor((14 - Double(calendar.component(.month, from: date))) / 12)
        let y = year + 4800 - a
        let m = Double(calendar.component(.month, from: date)) + 12 * a - 3
        let day = Double(calendar.component(.day, from: date))
        let jd = day + floor((153 * m + 2) / 5) + 365 * y + floor(y / 4) - floor(y / 100) + floor(y / 400) - 32045

        // Julian century
        let jc = (jd - 2451545.0) / 36525.0

        // Solar calculations
        let geomMeanLongSun = (280.46646 + jc * (36000.76983 + 0.0003032 * jc)).truncatingRemainder(dividingBy: 360)
        let geomMeanAnomSun = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)
        let eccentEarthOrbit = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)

        let anomRad = geomMeanAnomSun * .pi / 180
        let sunEqOfCtr = sin(anomRad) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
            + sin(2 * anomRad) * (0.019993 - 0.000101 * jc)
            + sin(3 * anomRad) * 0.000289

        let sunTrueLong = geomMeanLongSun + sunEqOfCtr
        let sunAppLong = sunTrueLong - 0.00569 - 0.00478 * sin((125.04 - 1934.136 * jc) * .pi / 180)

        let meanObliqEcliptic = 23 + (26 + ((21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813)))) / 60) / 60
        let obliqCorr = meanObliqEcliptic + 0.00256 * cos((125.04 - 1934.136 * jc) * .pi / 180)

        let sunDeclin = asin(sin(obliqCorr * .pi / 180) * sin(sunAppLong * .pi / 180)) * 180 / .pi

        // Equation of time
        let tanHalfObliq = tan(obliqCorr * .pi / 360)
        let y2 = tanHalfObliq * tanHalfObliq
        let longRad = geomMeanLongSun * .pi / 180
        let eqOfTime = 4 * (y2 * sin(2 * longRad)
            - 2 * eccentEarthOrbit * sin(anomRad)
            + 4 * eccentEarthOrbit * y2 * sin(anomRad) * cos(2 * longRad)
            - 0.5 * y2 * y2 * sin(4 * longRad)
            - 1.25 * eccentEarthOrbit * eccentEarthOrbit * sin(2 * anomRad)) * 180 / .pi

        // Hour angle
        let latRad = latitude * .pi / 180
        let declinRad = sunDeclin * .pi / 180
        let zenith = 90.833 * .pi / 180

        let cosHA = (cos(zenith) / (cos(latRad) * cos(declinRad))) - tan(latRad) * tan(declinRad)

        guard cosHA >= -1 && cosHA <= 1 else {
            // Polar day or polar night
            return (6.0, 22.0)
        }

        let ha = acos(cosHA) * 180 / .pi

        // Timezone offset in hours
        let tzOffset = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600.0

        let solarNoon = (720 - 4 * longitude - eqOfTime + tzOffset * 60) / 1440

        let sunrise = (solarNoon * 1440 - ha * 4) / 60  // hours
        let sunset = (solarNoon * 1440 + ha * 4) / 60   // hours

        guard sunrise.isFinite && sunset.isFinite else {
            return (6.0, 22.0)
        }

        return (sunrise, sunset)
    }

    /// Returns true if the given date/time falls between sunrise and sunset.
    static func isDay(date: Date, latitude: Double, longitude: Double) -> Bool {
        let (sunrise, sunset) = getSunriseSunset(date: date, latitude: latitude, longitude: longitude)
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        let currentHour = hour + minute / 60.0
        return currentHour >= sunrise && currentHour < sunset
    }
}
