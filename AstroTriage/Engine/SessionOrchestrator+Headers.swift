// Background header-enrichment extension for SessionOrchestrator.
//
// Step 4: pulls enrichWithHeaders out of TriageViewModel. The method
// reads FITS/XISF headers in parallel for every loaded image, applies
// the parsed metadata back into ImageEntry fields (filter, gain, temp,
// WCS, pier side, etc.), then triggers all the post-enrichment hooks
// that depend on having full header data: moon data, Bortle refinement,
// quality scoring, meridian flip detection, WCS alignment, community
// baseline fetch, and adaptive column reordering.
//
// The body is large but mostly mechanical header → ImageEntry mapping.
// Most of the post-enrichment hooks (computeMoonData, applyWCSAlignment,
// detectMeridianFlip, etc.) still live on TriageViewModel and migrate in
// step 5; for now they're reached through SessionHost bridge methods.
import Foundation

extension SessionOrchestrator {
    /// Read FITS/XISF headers for every loaded image in parallel, apply the
    /// authoritative metadata back into ImageEntry fields, and dispatch the
    /// post-enrichment cascade (moon, Bortle, scoring, meridian flip, WCS,
    /// community baseline, AIsaac profile learn, column reorder, debayer
    /// re-cache for OSC sessions).
    ///
    /// Header reading is concurrent (capped at 8 streams for SSD queue depth);
    /// values are batched onto the main actor so the UI sees one coherent
    /// update instead of per-frame churn.
    func enrichWithHeaders() {
        guard let host = host else { return }
        headerEnrichmentTask?.cancel()
        // Use decodingURL for actual file I/O (points to local cache for NAS files)
        // but keep original url as the dictionary key for matching
        let urls = host.images.map { $0.url }
        let readURLs = host.images.map { $0.decodingURL }
        let total = urls.count
        host.loadingPhase = .readingHeaders
        benchmarkStats.markHeaderEnrichStart()
        host.headerReadCount = 0
        host.headerReadTotal = total
        host.headerProgress = 0
        host.headerReadStartTime = Date()
        host.headerEstimatedSecondsRemaining = nil

        // Cap concurrency: ~8 for local SSD (queue depth), ~4 for network
        _ = min(8, ProcessInfo.processInfo.activeProcessorCount)

        headerEnrichmentTask = Task.detached(priority: .utility) { [weak self] in
            // Read all headers in parallel using concurrentPerform
            var allHeaders = Array(repeating: [String: String](), count: total)
            let headerLock = NSLock()
            let progressCounter = NSLock()
            var progressCount = 0

            DispatchQueue.concurrentPerform(iterations: total) { index in
                let headers = MetadataExtractor.readHeaders(from: readURLs[index])
                headerLock.lock()
                allHeaders[index] = headers
                headerLock.unlock()

                // Update progress periodically (every 8 files to avoid UI thrashing)
                progressCounter.lock()
                progressCount += 1
                let currentProgress = progressCount
                progressCounter.unlock()

                if currentProgress % 8 == 0 || currentProgress == total {
                    Task { @MainActor in
                        guard let host = self?.host else { return }
                        host.headerReadCount = currentProgress
                        host.headerProgress = total > 0 ? Double(currentProgress) / Double(total) : 0
                        // Compute time estimate after 20 items (enough for stable average)
                        if currentProgress >= 20, let startTime = host.headerReadStartTime {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let avgPerItem = elapsed / Double(currentProgress)
                            let remaining = Int(avgPerItem * Double(total - currentProgress))
                            host.headerEstimatedSecondsRemaining = max(1, remaining)
                        }
                    }
                }
            }

            // Apply all headers in one batch on main actor.
            // Use URL-based lookup instead of index-based to handle reordering:
            // images may get sorted by quality scoring while headers are being read.
            var headersByURL: [URL: [String: String]] = [:]
            headersByURL.reserveCapacity(total)
            for index in 0..<total {
                let headers = allHeaders[index]
                if !headers.isEmpty { headersByURL[urls[index]] = headers }
            }

            await MainActor.run {
                guard let self = self, let host = self.host else { return }
                var foundOSC = false

                for index in host.images.indices {
                    guard let headers = headersByURL[host.images[index].url] else { continue }

                    // Apply header values (authoritative over filename)
                    if let filter = headers["FILTER"], !filter.isEmpty {
                        host.images[index].filter = filter
                    }
                    if let exp = headers["EXPTIME"] ?? headers["EXPOSURE"], let val = Double(exp) {
                        host.images[index].exposure = val
                    }
                    if let gain = headers["GAIN"], let val = Int(gain) {
                        host.images[index].gain = val
                    }
                    if let temp = headers["CCD-TEMP"], let val = Double(temp) {
                        host.images[index].sensorTemp = val
                    }
                    if let fwhm = headers["STARFWHM"] ?? headers["FWHM"], let val = Double(fwhm) {
                        host.images[index].fwhm = val
                    }
                    if let obj = headers["OBJECT"], !obj.isEmpty {
                        host.images[index].target = obj
                    }
                    if let cam = headers["INSTRUME"], !cam.isEmpty {
                        host.images[index].camera = cam
                    }
                    if let scope = headers["TELESCOP"], !scope.isEmpty {
                        host.images[index].telescope = scope
                    }
                    if let bayer = headers["BAYERPAT"], !bayer.isEmpty {
                        host.images[index].bayerPattern = bayer.trimmingCharacters(in: .whitespaces).uppercased()
                    }
                    if let off = headers["OFFSET"], let val = Int(off) {
                        host.images[index].offset = val
                    }
                    if let xbin = headers["XBINNING"], let val = Int(xbin) {
                        host.images[index].binning = host.images[index].binning ?? "\(val)x\(val)"
                    }
                    if let focTemp = headers["FOCTEMP"], let val = Double(focTemp) {
                        host.images[index].focuserTemp = val
                    }
                    // Focal length and pixel size for adaptive trailing thresholds
                    if let fl = headers["FOCALLEN"], let val = Double(fl), val > 0 {
                        host.images[index].focalLength = val
                    }
                    if let px = headers["XPIXSZ"], let val = Double(px), val > 0 {
                        host.images[index].pixelSizeMicrons = val
                    }
                    // Plate-solved center coordinates for pointing offset detection
                    // CRVAL1/CRVAL2 = plate-solved WCS center (primary)
                    // RA/DEC = NINA writes target coords in decimal degrees (fallback)
                    if let ra = headers["CRVAL1"], let val = Double(ra) {
                        host.images[index].solvedRA = val
                    } else if host.images[index].solvedRA == nil,
                              let ra = headers["RA"], let val = Double(ra) {
                        host.images[index].solvedRA = val
                    }
                    if let dec = headers["CRVAL2"], let val = Double(dec) {
                        host.images[index].solvedDec = val
                    } else if host.images[index].solvedDec == nil,
                              let dec = headers["DEC"], let val = Double(dec) {
                        host.images[index].solvedDec = val
                    }
                    // WCS rotation from plate solve for meridian flip detection
                    if host.images[index].wcsRotation == nil {
                        if let crota2 = headers["CROTA2"], let val = Double(crota2) {
                            host.images[index].wcsRotation = val
                        } else if let cd11 = headers["CD1_1"], let cd12 = headers["CD1_2"],
                                  let v11 = Double(cd11), let v12 = Double(cd12) {
                            host.images[index].wcsRotation = atan2(-v12, v11) * 180.0 / .pi
                        }
                    }
                    // Full WCS plate-solve data for CD-matrix based display alignment.
                    // Used by DisplayAligner as the primary alignment path — exact,
                    // filter-independent, ~100x faster than star matching.
                    if let v = headers["CRPIX1"] { host.images[index].wcsCRPIX1 = Double(v) }
                    if let v = headers["CRPIX2"] { host.images[index].wcsCRPIX2 = Double(v) }
                    if let v = headers["CD1_1"]  { host.images[index].wcsCD11 = Double(v) }
                    if let v = headers["CD1_2"]  { host.images[index].wcsCD12 = Double(v) }
                    if let v = headers["CD2_1"]  { host.images[index].wcsCD21 = Double(v) }
                    if let v = headers["CD2_2"]  { host.images[index].wcsCD22 = Double(v) }
                    // Image dimensions from FITS headers — needed by WCS alignment to
                    // normalize the pixel-space transform into UV space. Populated here
                    // so applyWCSAlignment() doesn't have to wait for frame decode.
                    if host.images[index].width == nil,
                       let v = headers["NAXIS1"], let w = Int(v), w > 0 {
                        host.images[index].width = w
                    }
                    if host.images[index].height == nil,
                       let v = headers["NAXIS2"], let h = Int(v), h > 0 {
                        host.images[index].height = h
                    }
                    // Site coordinates for AIsaac location-aware language detection
                    // NINA writes SITELAT/SITELONG, some software uses LAT-OBS/LONG-OBS or OBSLAT/OBSLONG
                    if host.images[index].siteLatitude == nil {
                        for key in ["SITELAT", "LAT-OBS", "OBSLAT", "SITELAT "] {
                            if let raw = headers[key], let val = Double(raw) {
                                host.images[index].siteLatitude = val
                                break
                            }
                        }
                    }
                    if host.images[index].siteLongitude == nil {
                        for key in ["SITELONG", "LONG-OBS", "OBSLONG", "SITELONG"] {
                            if let raw = headers[key], let val = Double(raw) {
                                host.images[index].siteLongitude = val
                                break
                            }
                        }
                    }
                    // DATE-LOC (NINA local capture time) is authoritative — always overrides filename date.
                    // DATE-OBS is only used as fallback when no date exists yet (it may contain
                    // unexpected values in some FITS writers, e.g. session-start or file-creation date).
                    if let dateLoc = headers["DATE-LOC"], !dateLoc.isEmpty, dateLoc.count >= 10 {
                        // DATE-LOC: unconditional override (fixes NINA $$DATENOW$$ after-midnight issue)
                        host.images[index].date = String(dateLoc.prefix(10))
                        if dateLoc.count >= 19, let tIndex = dateLoc.firstIndex(of: "T") {
                            let timeStart = dateLoc.index(after: tIndex)
                            let timeEnd = dateLoc.index(timeStart, offsetBy: 8, limitedBy: dateLoc.endIndex) ?? dateLoc.endIndex
                            host.images[index].time = String(dateLoc[timeStart..<timeEnd])
                        }
                    } else if let dateObs = headers["DATE-OBS"], !dateObs.isEmpty, dateObs.count >= 10 {
                        // DATE-OBS: fallback only — fill in if no date set yet
                        host.images[index].date = host.images[index].date ?? String(dateObs.prefix(10))
                        if dateObs.count >= 19, let tIndex = dateObs.firstIndex(of: "T") {
                            let timeStart = dateObs.index(after: tIndex)
                            let timeEnd = dateObs.index(timeStart, offsetBy: 8, limitedBy: dateObs.endIndex) ?? dateObs.endIndex
                            host.images[index].time = host.images[index].time ?? String(dateObs[timeStart..<timeEnd])
                        }
                    }

                    // Twilight phase: classify sun position at capture time
                    // DATE-OBS is UTC (FITS standard), use with site coordinates
                    if host.images[index].twilightPhase == nil,
                       let lat = host.images[index].siteLatitude,
                       let lon = host.images[index].siteLongitude,
                       let dateObs = headers["DATE-OBS"], dateObs.count >= 19 {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                        df.timeZone = TimeZone(identifier: "UTC")
                        df.locale = Locale(identifier: "en_US_POSIX")
                        // Try with fractional seconds first, then without
                        let cleanDate = String(dateObs.prefix(19))
                        if let utcDate = df.date(from: cleanDate) {
                            host.images[index].twilightPhase = SunCalculator.twilightPhase(
                                utcDate: utcDate, latitude: lat, longitude: lon
                            )
                        }
                    }

                    // Ambient temperature
                    if let ambTemp = headers["AMBTEMP"] ?? headers["AMBIENT"], let val = Double(ambTemp) {
                        host.images[index].ambientTemp = val
                    }
                    // Frame type from IMAGETYP/FRAME header (authoritative)
                    if let imageType = headers["IMAGETYP"] ?? headers["FRAME"], !imageType.isEmpty {
                        host.images[index].frameType = MetadataExtractor.normalizeFrameType(imageType)
                    }

                    // Pier side for meridian flip detection
                    // Case-insensitive key lookup (XISF may store differently than FITS)
                    // FITS values may be wrapped in single quotes (e.g. "'East'"), strip them
                    let pierVal = headers["PIERSIDE"] ?? headers.first(where: { $0.key.uppercased() == "PIERSIDE" })?.value
                    if let pier = pierVal, !pier.isEmpty {
                        let cleaned = pier.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                            .uppercased()
                        if cleaned == "EAST" || cleaned == "WEST" {
                            host.images[index].pierSide = cleaned
                        }
                    }

                    // Rotator angle for meridian flip fallback (ASIAIR/AM5 mounts)
                    let rotVal = headers["ROTATOR"] ?? headers.first(where: { $0.key.uppercased() == "ROTATOR" })?.value
                    if let rot = rotVal, let val = Double(rot) {
                        host.images[index].rotatorAngle = val
                    }

                    // Object coordinates for meridian flip matching
                    // Case-insensitive key lookup, strip FITS single-quote wrappers
                    let raVal = headers["OBJCTRA"] ?? headers.first(where: { $0.key.uppercased() == "OBJCTRA" })?.value
                    if let ra = raVal, !ra.isEmpty {
                        host.images[index].objctRA = ra.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }
                    let decVal = headers["OBJCTDEC"] ?? headers.first(where: { $0.key.uppercased() == "OBJCTDEC" })?.value
                    if let dec = decVal, !dec.isEmpty {
                        host.images[index].objctDec = dec.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }

                    if host.images[index].bayerPattern != nil {
                        foundOSC = true
                    }
                }

                host.needsTableRefresh = true
                host.loadingPhase = .none
                host.headerEstimatedSecondsRemaining = nil
                host.headerReadStartTime = nil
                self.benchmarkStats.markHeaderEnrichEnd()
                self.sessionOverviewModel.updateStats(from: host.images)
                host.hasOSCImages = foundOSC
                // Compute moon illumination + target distance (needs date + coordinates from headers)
                host.computeMoonData()
                // Refine Bortle online (one call per unique coordinate, fire-and-forget)
                host.refineBortleOnline()
                // Compute relative quality scores now that all header metadata is available
                host.recomputeQualityScores()
                // Fix for MainActor Task delivery race (same as local path)
                host.scheduleQualityRescore()
                host.detectMeridianFlip()
                // Apply WCS-based alignment (fast, exact) now that headers are available.
                // For every frame with complete plate-solve data, overrides whatever the
                // star-based prefetch alignment computed earlier with an exact transform.
                host.applyWCSAlignment()

                // Fetch community baseline for cold-start calibration (async, non-blocking)
                if let fp = host.currentSetupFingerprint {
                    Task {
                        let baseline = await CommunityDetectionService.shared.fetchCommunityBaseline(fingerprint: fp)
                        await MainActor.run {
                            guard let host = self.host else { return }
                            if let bl = baseline, host.communityBaseline == nil {
                                host.communityBaseline = bl
                                // Recompute scores with community baseline if local calibration insufficient
                                if !CalibrationDatabase.shared.profile(for: fp).hasLearned {
                                    host.recomputeQualityScores()
                                }
                            }
                        }
                    }
                }

                // Learn equipment/location/targets for AIsaac user profile
                var profile = AIsaacUserProfile.load()
                profile.learnFrom(images: host.images)
                profile.save()

                // Auto-reorder columns based on session composition (4 cases)
                // Always apply — each session type needs its own layout
                let uniqueTargets = Set(host.images.compactMap { $0.target?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                let uniqueFilters = Set(host.images.compactMap { $0.filter?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                let isMultiObject = uniqueTargets.count > 1
                let isMultiFilter = uniqueFilters.count > 1
                host.pendingColumnOrder = ColumnDefinition.recommendedColumnOrder(
                    isMultiObject: isMultiObject, isMultiFilter: isMultiFilter
                )
                // Update rotation for current image now that pier side data is available
                host.updateMeridianRotation()

                // Detect mixed sensor dimensions and warn the user
                host.checkForMixedDimensions()

                // If debayer is enabled and OSC images were found, previews were cached
                // without bayerPattern (headers weren't available yet). Re-cache with debayer.
                if foundOSC && host.debayerEnabled {
                    self.prefetchCache?.invalidateAll()
                    self.startFullPrefetch()
                    // Also re-display current image with debayer applied
                    host.displayCurrentImage()
                }
            }
        }
    }
}
