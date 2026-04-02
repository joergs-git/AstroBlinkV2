// ****************************************************************************
// AstroBlinkImporter.js — PixInsight Script
// Import AstroBlink triage results into PixInsight.
//
// Reads AstroBlinkV2_SSWEIGHT.csv from an imaging session folder,
// displays a triage table with color-coded quality tiers, and optionally
// writes SSWEIGHT/PSFSWGHT keywords into FITS/XISF headers for WBPP.
//
// Platform: PixInsight 1.8.9+ (PJSR / SpiderMonkey 24 — ES5 only)
// Author: joergsflow
// License: MIT
// ****************************************************************************

#feature-id AstroBlinkImporter : Batch Processing > AstroBlink Importer
#feature-info Import AstroBlink triage results and SSWEIGHT values into PixInsight.\
   <br><br>\
   Reads the AstroBlinkV2_SSWEIGHT.csv file from your session folder \
   and displays a sortable triage table with color-coded quality tiers, \
   SSWEIGHT, and PSFSignalWeight values.\
   <br><br>\
   Optionally writes SSWEIGHT and PSFSWGHT keywords into FITS/XISF \
   headers for use with WeightedBatchPreProcessing (WBPP).\
   <br><br>\
   Requires AstroBlink (macOS) — https://github.com/joergs-git/AstroBlinkV2

#include <pjsr/DataType.jsh>
#include <pjsr/StdButton.jsh>
#include <pjsr/StdIcon.jsh>
#include <pjsr/FrameStyle.jsh>
#include <pjsr/TextAlign.jsh>
#include <pjsr/Sizer.jsh>

// ============================================================================
// Configuration
// ============================================================================

var SCRIPT_NAME = "AstroBlinkImporter";
var SCRIPT_VERSION = "1.1.0";
var CSV_FILENAME = "AstroBlinkV2_SSWEIGHT.csv";

// Column definitions — match AstroBlink's actual CSV export format:
// Filename,SSWEIGHT,PSFSWGHT,QualityTier,TrailingScore,FWHM,HFR,Ecc,SNR,StarCount
var COL_FILENAME  = 0;
var COL_QUALITY   = 1;
var COL_SSWEIGHT  = 2;
var COL_PSFSWGHT  = 3;
var COL_FWHM      = 4;
var COL_STARS     = 5;
var COL_SNR       = 6;
var COL_TRAILING  = 7;
var NUM_COLUMNS   = 8;

// ============================================================================
// Quality Tier Display
// ============================================================================

// AstroBlink CSV exports tier names as lowercase text
var TIER_DISPLAY = {
   "excellent":  "Excellent",
   "good":       "Good",
   "borderline": "Borderline",
   "trash":      "Trash",
   "uncertain":  "Uncertain"
};

// ARGB colors for tier text in TreeBox
var TIER_TEXT_COLORS = {
   "excellent":  0xFF22CC22,   // Bright green
   "good":       0xFF44AA44,   // Green
   "borderline": 0xFFDD8800,   // Orange
   "trash":      0xFFDD4444,   // Red
   "uncertain":  0xFF4488DD    // Blue
};

function tierDisplay(tierValue) {
   return TIER_DISPLAY[tierValue] || tierValue || "";
}

function tierTextColor(tierValue) {
   return TIER_TEXT_COLORS[tierValue] || 0xFF888888;
}

// Numeric sort rank for tiers (lower = worse)
function tierSortRank(tierValue) {
   var ranks = { "trash": 0, "uncertain": 1, "borderline": 2, "good": 3, "excellent": 4 };
   return ranks.hasOwnProperty(tierValue) ? ranks[tierValue] : -1;
}

// ============================================================================
// Platform Detection
// ============================================================================

function isMacOS() {
   // PixInsight temp dir starts with / on macOS, C:\ on Windows
   var tmp = File.systemTempDirectory;
   return tmp.indexOf("/") === 0;
}

function isAstroBlinkInstalled() {
   if (!isMacOS()) return false;
   var paths = [
      "/Applications/AstroBlinkV2.app",
      File.homeDirectory + "/Applications/AstroBlinkV2.app"
   ];
   for (var i = 0; i < paths.length; i++) {
      if (File.exists(paths[i])) return true;
   }
   return false;
}

// ============================================================================
// CSV Parser
// ============================================================================

/**
 * Parse AstroBlinkV2_SSWEIGHT.csv into an array of objects.
 * Actual CSV columns from AstroBlink:
 *   Filename,SSWEIGHT,PSFSWGHT,QualityTier,TrailingScore,FWHM,HFR,Ecc,SNR,StarCount
 */
function parseCSV(filePath) {
   var lines = File.readLines(filePath);
   if (lines.length < 2) {
      Console.warningln("AstroBlinkImporter: CSV has no data rows");
      return [];
   }

   // Parse header row to get column indices dynamically
   var headers = lines[0].split(",");
   for (var h = 0; h < headers.length; h++) {
      headers[h] = headers[h].trim();
   }

   var records = [];
   for (var i = 1; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.length === 0) continue;

      // Handle quoted fields (in case filenames contain commas)
      var fields = splitCSVLine(line);
      var record = {};
      for (var j = 0; j < headers.length && j < fields.length; j++) {
         record[headers[j]] = fields[j].trim();
      }
      records.push(record);
   }

   Console.writeln(format("AstroBlinkImporter: Parsed %d records from %s", records.length, filePath));
   return records;
}

/**
 * Split a CSV line handling quoted fields.
 */
function splitCSVLine(line) {
   var fields = [];
   var current = "";
   var inQuotes = false;
   for (var i = 0; i < line.length; i++) {
      var ch = line.charAt(i);
      if (ch === '"') {
         inQuotes = !inQuotes;
      } else if (ch === ',' && !inQuotes) {
         fields.push(current);
         current = "";
      } else {
         current += ch;
      }
   }
   fields.push(current);
   return fields;
}

// ============================================================================
// File Finder
// ============================================================================

/**
 * Search for AstroBlinkV2_SSWEIGHT.csv in a folder, its parent,
 * and one level of subfolders (NINA organizes by target/filter).
 */
function findCSV(sessionFolder) {
   // Direct path
   var direct = sessionFolder + "/" + CSV_FILENAME;
   if (File.exists(direct)) return direct;

   // Parent folder (CSV is written to session root)
   var parent = File.extractDrive(sessionFolder) + File.extractDirectory(sessionFolder);
   if (parent.length > 0 && parent !== sessionFolder) {
      var parentPath = parent + "/" + CSV_FILENAME;
      // extractDirectory may include trailing slash
      if (parent.charAt(parent.length - 1) === "/") {
         parentPath = parent + CSV_FILENAME;
      }
      if (File.exists(parentPath)) return parentPath;
   }

   // Search one level of subfolders
   var search = new FileFind;
   if (search.begin(sessionFolder + "/*")) {
      do {
         if (search.isDirectory && search.name !== "." && search.name !== "..") {
            var subPath = sessionFolder + "/" + search.name + "/" + CSV_FILENAME;
            if (File.exists(subPath)) return subPath;
         }
      } while (search.next());
   }

   return null;
}

// ============================================================================
// FITS/XISF Header Writing
// ============================================================================

/**
 * Write SSWEIGHT and PSFSWGHT keywords to a FITS or XISF file.
 *
 * Uses the FileFormatInstance read-modify-write pattern (official PJSR API).
 * There is no "edit" mode — the full image must be read, keywords modified
 * in memory, then written back. This is slow for large files but reliable.
 *
 * Based on BatchFormatConversion.js pattern from PTeam.
 */
function writeKeywordsToFile(filePath, ssweight, psfswght) {
   var ext = File.extractExtension(filePath).toLowerCase();
   var isFITS = (ext === ".fits" || ext === ".fit" || ext === ".fts");
   var isXISF = (ext === ".xisf");

   if (!isFITS && !isXISF) {
      Console.warningln("Unsupported format: " + ext);
      return false;
   }

   try {
      // Phase 1: READ — open file and read image + metadata
      var readFmt = new FileFormat(ext, true/*toRead*/, false/*toWrite*/);
      var fi = new FileFormatInstance(readFmt);
      var desc = fi.open(filePath, "" /*hints*/);
      if (desc.length < 1) {
         Console.warningln("Cannot open: " + filePath);
         fi.close();
         return false;
      }

      // Create image matching the file's format
      var image = new Image(1, 1, 1, ColorSpace_Gray,
                            desc[0].bitsPerSample,
                            desc[0].ieeefpSampleFormat ? SampleType_Real : SampleType_Integer);
      fi.readImage(image);
      var keywords = fi.keywords;
      var iccProfile = fi.iccProfile;
      fi.close();

      // Phase 2: MODIFY — remove old and add new keywords
      var filtered = [];
      for (var k = 0; k < keywords.length; k++) {
         if (keywords[k].name !== "SSWEIGHT" && keywords[k].name !== "PSFSWGHT") {
            filtered.push(keywords[k]);
         }
      }
      filtered.push(new FITSKeyword("SSWEIGHT",
         format("%.4f", ssweight),
         "AstroBlink sub-frame quality weight"));
      if (psfswght !== undefined && psfswght !== null && !isNaN(psfswght)) {
         filtered.push(new FITSKeyword("PSFSWGHT",
            format("%.4f", psfswght),
            "AstroBlink PSF signal weight"));
      }

      // Phase 3: WRITE — overwrite original file with updated keywords
      var writeFmt = new FileFormat(ext, false/*toRead*/, true/*toWrite*/);
      var fo = new FileFormatInstance(writeFmt);
      fo.create(filePath, "" /*hints*/);
      fo.setOptions(new ImageDescription(desc[0]));
      fo.keywords = filtered;
      if (iccProfile) fo.iccProfile = iccProfile;
      fo.writeImage(image);
      fo.close();

      image.free();
      return true;

   } catch (e) {
      Console.warningln("Error writing keywords to " + filePath + ": " + e.message);
      return false;
   }
}

// ============================================================================
// Sorting Helpers
// ============================================================================

/**
 * Sort records array by a given key.
 * Returns a new sorted array (does not modify original).
 */
function sortRecords(records, key, ascending, isNumeric) {
   var sorted = records.slice(); // shallow copy
   sorted.sort(function(a, b) {
      var va = a[key] || "";
      var vb = b[key] || "";
      var result;

      if (key === "QualityTier") {
         // Special: sort by tier rank
         result = tierSortRank(va) - tierSortRank(vb);
      } else if (isNumeric) {
         var na = parseFloat(va) || 0;
         var nb = parseFloat(vb) || 0;
         result = na - nb;
      } else {
         result = va < vb ? -1 : va > vb ? 1 : 0;
      }

      return ascending ? result : -result;
   });
   return sorted;
}

// ============================================================================
// Main Dialog
// ============================================================================

function AstroBlinkImporterDialog() {
   this.__base__ = Dialog;
   this.__base__();

   this.windowTitle = SCRIPT_NAME + " v" + SCRIPT_VERSION;
   this.minWidth = 780;
   this.records = [];         // Original parsed records
   this.sortedRecords = [];   // Currently displayed (sorted) records
   this.sessionFolder = "";
   this.sortColumn = "SSWEIGHT";
   this.sortAscending = false;

   var self = this;

   // ── Header ──
   var titleLabel = new Label(this);
   titleLabel.text = "AstroBlink Importer for PixInsight";
   titleLabel.textAlignment = TextAlign_Center;
   titleLabel.styleSheet = "QLabel { font-size: 14pt; font-weight: bold; }";

   var descLabel = new Label(this);
   descLabel.text = "Import triage results and quality weights from AstroBlink.";
   descLabel.textAlignment = TextAlign_Center;

   // ── Folder Selection ──
   var folderLabel = new Label(this);
   folderLabel.text = "Session Folder:";

   this.folderEdit = new Edit(this);
   this.folderEdit.readOnly = true;
   this.folderEdit.minWidth = 400;

   this.browseButton = new PushButton(this);
   this.browseButton.text = "Browse...";
   this.browseButton.onClick = function() {
      var dir = new GetDirectoryDialog();
      dir.caption = "Select Session Folder";
      if (dir.execute()) {
         self.folderEdit.text = dir.directory;
         self.sessionFolder = dir.directory;
         self.loadCSV();
      }
   };

   // ── Sort Controls ──
   var sortLabel = new Label(this);
   sortLabel.text = "Sort by:";

   this.sortCombo = new ComboBox(this);
   this.sortCombo.addItem("SSWEIGHT (best first)");
   this.sortCombo.addItem("SSWEIGHT (worst first)");
   this.sortCombo.addItem("Quality (best first)");
   this.sortCombo.addItem("Quality (worst first)");
   this.sortCombo.addItem("FWHM (best first)");
   this.sortCombo.addItem("Stars (most first)");
   this.sortCombo.addItem("SNR (best first)");
   this.sortCombo.addItem("Filename");
   this.sortCombo.currentItem = 0; // Default: SSWEIGHT desc
   this.sortCombo.onItemSelected = function(index) {
      var sortConfigs = [
         { key: "SSWEIGHT",      asc: false, num: true },
         { key: "SSWEIGHT",      asc: true,  num: true },
         { key: "QualityTier",   asc: false, num: false },
         { key: "QualityTier",   asc: true,  num: false },
         { key: "FWHM",          asc: true,  num: true },
         { key: "StarCount",     asc: false, num: true },
         { key: "SNR",           asc: false, num: true },
         { key: "Filename",      asc: true,  num: false }
      ];
      if (index >= 0 && index < sortConfigs.length) {
         var cfg = sortConfigs[index];
         self.sortColumn = cfg.key;
         self.sortAscending = cfg.asc;
         self.refreshTreeBox();
      }
   };

   // ── TreeBox for results ──
   this.treeBox = new TreeBox(this);
   this.treeBox.alternateRowColor = true;
   this.treeBox.headerVisible = true;
   this.treeBox.numberOfColumns = NUM_COLUMNS;
   this.treeBox.setHeaderText(COL_FILENAME, "Filename");
   this.treeBox.setHeaderText(COL_QUALITY,  "Quality");
   this.treeBox.setHeaderText(COL_SSWEIGHT, "SSWEIGHT");
   this.treeBox.setHeaderText(COL_PSFSWGHT, "PSFSWGHT");
   this.treeBox.setHeaderText(COL_FWHM,     "FWHM");
   this.treeBox.setHeaderText(COL_STARS,    "Stars");
   this.treeBox.setHeaderText(COL_SNR,      "SNR");
   this.treeBox.setHeaderText(COL_TRAILING, "Trailing");
   this.treeBox.setMinSize(760, 350);

   // Set column widths
   this.treeBox.setColumnWidth(COL_FILENAME, 280);
   this.treeBox.setColumnWidth(COL_QUALITY,  75);
   this.treeBox.setColumnWidth(COL_SSWEIGHT, 70);
   this.treeBox.setColumnWidth(COL_PSFSWGHT, 70);
   this.treeBox.setColumnWidth(COL_FWHM,     55);
   this.treeBox.setColumnWidth(COL_STARS,    55);
   this.treeBox.setColumnWidth(COL_SNR,      55);
   this.treeBox.setColumnWidth(COL_TRAILING, 60);

   // ── Summary ──
   this.summaryLabel = new Label(this);
   this.summaryLabel.text = "No data loaded. Click Browse to select a session folder.";

   this.statsLabel = new Label(this);
   this.statsLabel.text = "";

   // ── Action Buttons ──
   this.writeButton = new PushButton(this);
   this.writeButton.text = "Write Keywords to Headers";
   this.writeButton.toolTip = "Write SSWEIGHT and PSFSWGHT into FITS/XISF headers for WBPP weighting.";
   this.writeButton.enabled = false;
   this.writeButton.onClick = function() {
      self.writeKeywordsToFiles();
   };

   this.closeButton = new PushButton(this);
   this.closeButton.text = "Close";
   this.closeButton.onClick = function() {
      self.cancel();
   };

   // ── Layout ──
   var folderSizer = new HorizontalSizer;
   folderSizer.spacing = 4;
   folderSizer.add(folderLabel);
   folderSizer.add(this.folderEdit, 100);
   folderSizer.add(this.browseButton);

   var sortSizer = new HorizontalSizer;
   sortSizer.spacing = 4;
   sortSizer.add(sortLabel);
   sortSizer.add(this.sortCombo);
   sortSizer.addStretch();

   var buttonSizer = new HorizontalSizer;
   buttonSizer.spacing = 8;
   buttonSizer.addStretch();
   buttonSizer.add(this.writeButton);
   buttonSizer.add(this.closeButton);

   this.sizer = new VerticalSizer;
   this.sizer.margin = 8;
   this.sizer.spacing = 6;
   this.sizer.add(titleLabel);
   this.sizer.add(descLabel);
   this.sizer.addSpacing(4);
   this.sizer.add(folderSizer);
   this.sizer.add(sortSizer);
   this.sizer.add(this.treeBox, 100);
   this.sizer.add(this.summaryLabel);
   this.sizer.add(this.statsLabel);
   this.sizer.add(buttonSizer);

   this.adjustToContents();
}

AstroBlinkImporterDialog.prototype = new Dialog;

// ── Load CSV and populate TreeBox ──

AstroBlinkImporterDialog.prototype.loadCSV = function() {
   this.treeBox.clear();
   this.records = [];
   this.sortedRecords = [];

   var csvPath = findCSV(this.sessionFolder);
   if (csvPath === null) {
      this.summaryLabel.text = "No " + CSV_FILENAME + " found in folder or parent.";
      this.statsLabel.text = "Run AstroBlink first and export SSWEIGHT to create the CSV.";
      this.writeButton.enabled = false;
      return;
   }

   this.records = parseCSV(csvPath);
   if (this.records.length === 0) {
      this.summaryLabel.text = "CSV is empty — no scored frames found.";
      this.statsLabel.text = "";
      this.writeButton.enabled = false;
      return;
   }

   // Sort and display
   this.sortedRecords = sortRecords(this.records, this.sortColumn, this.sortAscending,
                                     this.sortColumn !== "QualityTier" && this.sortColumn !== "Filename");
   this.populateTreeBox();
   this.updateSummary();
   this.writeButton.enabled = true;
};

// ── Refresh TreeBox after sort change ──

AstroBlinkImporterDialog.prototype.refreshTreeBox = function() {
   if (this.records.length === 0) return;
   var isNumeric = (this.sortColumn !== "QualityTier" && this.sortColumn !== "Filename");
   this.sortedRecords = sortRecords(this.records, this.sortColumn, this.sortAscending, isNumeric);
   this.treeBox.clear();
   this.populateTreeBox();
};

// ── Populate TreeBox from sortedRecords ──

AstroBlinkImporterDialog.prototype.populateTreeBox = function() {
   for (var i = 0; i < this.sortedRecords.length; i++) {
      var r = this.sortedRecords[i];
      var node = new TreeBoxNode(this.treeBox);

      // Filename
      node.setText(COL_FILENAME, r["Filename"] || "");

      // Quality tier — color coded
      var tier = (r["QualityTier"] || "").toLowerCase();
      node.setText(COL_QUALITY, tierDisplay(tier));
      node.setTextColor(COL_QUALITY, tierTextColor(tier));

      // Numeric columns
      node.setText(COL_SSWEIGHT, formatNum(r["SSWEIGHT"], 2));
      node.setText(COL_PSFSWGHT, formatNum(r["PSFSWGHT"], 2));
      node.setText(COL_FWHM,    formatNum(r["FWHM"], 2));
      node.setText(COL_STARS,   r["StarCount"] || "");
      node.setText(COL_SNR,     formatNum(r["SNR"], 1));
      node.setText(COL_TRAILING, formatNum(r["TrailingScore"], 3));

      // Right-align numeric columns
      node.setAlignment(COL_SSWEIGHT, TextAlign_Right);
      node.setAlignment(COL_PSFSWGHT, TextAlign_Right);
      node.setAlignment(COL_FWHM,     TextAlign_Right);
      node.setAlignment(COL_STARS,    TextAlign_Right);
      node.setAlignment(COL_SNR,      TextAlign_Right);
      node.setAlignment(COL_TRAILING, TextAlign_Right);
   }
};

/**
 * Format a numeric string with fixed decimals.
 * Returns empty string for empty/invalid input.
 */
function formatNum(value, decimals) {
   if (!value || value.length === 0) return "";
   var n = parseFloat(value);
   if (isNaN(n)) return value;
   return n.toFixed(decimals);
}

// ── Update summary stats ──

AstroBlinkImporterDialog.prototype.updateSummary = function() {
   var total = this.records.length;
   var tierCounts = { "excellent": 0, "good": 0, "borderline": 0, "trash": 0, "uncertain": 0 };
   var sumSSW = 0;
   var countSSW = 0;
   var sumFWHM = 0;
   var countFWHM = 0;

   for (var i = 0; i < this.records.length; i++) {
      var r = this.records[i];
      var tier = (r["QualityTier"] || "").toLowerCase();
      if (tierCounts.hasOwnProperty(tier)) {
         tierCounts[tier]++;
      }
      var ssw = parseFloat(r["SSWEIGHT"]);
      if (!isNaN(ssw)) { sumSSW += ssw; countSSW++; }
      var fw = parseFloat(r["FWHM"]);
      if (!isNaN(fw)) { sumFWHM += fw; countFWHM++; }
   }

   var kept = tierCounts["excellent"] + tierCounts["good"];
   var keptPct = total > 0 ? (kept / total * 100) : 0;

   this.summaryLabel.text = format(
      "%d frames — %d Excellent, %d Good, %d Borderline, %d Trash (%.0f%% kept)",
      total, tierCounts["excellent"], tierCounts["good"],
      tierCounts["borderline"], tierCounts["trash"], keptPct
   );

   // Additional stats row
   var avgSSW = countSSW > 0 ? sumSSW / countSSW : 0;
   var avgFWHM = countFWHM > 0 ? sumFWHM / countFWHM : 0;
   var statsText = format("Avg SSWEIGHT: %.1f", avgSSW);
   if (countFWHM > 0) {
      statsText += format("  |  Avg FWHM: %.2f px", avgFWHM);
   }
   this.statsLabel.text = statsText;
};

// ── Write keywords to file headers ──

AstroBlinkImporterDialog.prototype.writeKeywordsToFiles = function() {
   if (this.records.length === 0) return;

   // Confirmation dialog
   var confirm = new MessageBox(
      format("Write SSWEIGHT/PSFSWGHT keywords to %d file headers?\n\n" +
             "This modifies your FITS/XISF files. Original header data is preserved.",
             this.records.length),
      SCRIPT_NAME, StdIcon_Question, StdButton_Yes, StdButton_No
   );
   if (confirm.execute() !== StdButton_Yes) return;

   var written = 0;
   var skipped = 0;
   var failed = 0;

   Console.writeln(format("<b>Writing keywords to %d files...</b>", this.records.length));
   Console.flush();

   for (var i = 0; i < this.records.length; i++) {
      var r = this.records[i];
      var filename = r["Filename"];
      if (!filename) { skipped++; continue; }

      var ssweight = parseFloat(r["SSWEIGHT"]);
      if (isNaN(ssweight)) { skipped++; continue; }

      var psfswght = r["PSFSWGHT"] ? parseFloat(r["PSFSWGHT"]) : null;

      // Find the actual file — try with original name first, then common extensions
      var filePath = this.findFile(filename);
      if (filePath === null) {
         Console.warningln("File not found: " + filename);
         skipped++;
         continue;
      }

      if (writeKeywordsToFile(filePath, ssweight, psfswght)) {
         written++;
         if ((written % 10) === 0) {
            Console.writeln(format("  %d / %d written...", written, this.records.length));
            Console.flush();
         }
      } else {
         failed++;
      }
   }

   var msg = format("Done! %d of %d files updated.", written, this.records.length);
   if (skipped > 0) msg += format("\n%d skipped (not found or no weight).", skipped);
   if (failed > 0) msg += format("\n%d failed (check Process Console for details).", failed);
   Console.writeln("<b>" + msg.replace(/\n/g, "</b>\n<b>") + "</b>");

   var result = new MessageBox(msg, SCRIPT_NAME, StdIcon_Information, StdButton_Ok);
   result.execute();
};

/**
 * Find a file in the session folder by filename.
 * Tries original name, then strips/adds common extensions.
 */
AstroBlinkImporterDialog.prototype.findFile = function(filename) {
   // Try exact path
   var fullPath = this.sessionFolder + "/" + filename;
   if (File.exists(fullPath)) return fullPath;

   // Try without extension + common extensions
   var baseName = filename.replace(/\.[^.]+$/, "");
   var extensions = [".fits", ".fit", ".fts", ".xisf"];
   for (var j = 0; j < extensions.length; j++) {
      var testPath = this.sessionFolder + "/" + baseName + extensions[j];
      if (File.exists(testPath)) return testPath;
   }

   // Search one level of subfolders (NINA organizes by filter/target)
   var search = new FileFind;
   if (search.begin(this.sessionFolder + "/*")) {
      do {
         if (search.isDirectory && search.name !== "." && search.name !== "..") {
            var subPath = this.sessionFolder + "/" + search.name + "/" + filename;
            if (File.exists(subPath)) return subPath;
            // Try extensions in subfolder
            for (var k = 0; k < extensions.length; k++) {
               var subTestPath = this.sessionFolder + "/" + search.name + "/" + baseName + extensions[k];
               if (File.exists(subTestPath)) return subTestPath;
            }
         }
      } while (search.next());
   }

   return null;
};

// ============================================================================
// Entry Point
// ============================================================================

function main() {
   Console.writeln(format("<b>%s v%s</b>", SCRIPT_NAME, SCRIPT_VERSION));
   Console.writeln("Import AstroBlink triage results into PixInsight");
   Console.writeln("---");
   Console.flush();

   // Platform check — informational, not blocking
   if (!isMacOS()) {
      var msg = new MessageBox(
         "AstroBlink is a macOS application.\n\n" +
         "This script can still import CSV files generated on a Mac.\n" +
         "Place the AstroBlinkV2_SSWEIGHT.csv in your session folder.\n\n" +
         "Download AstroBlink:\nhttps://github.com/joergs-git/AstroBlinkV2",
         SCRIPT_NAME, StdIcon_Information, StdButton_Ok
      );
      msg.execute();
      // Don't return — allow CSV import even on Windows if user has the file
   }
   // Installation check — informational only
   else if (!isAstroBlinkInstalled()) {
      var msg = new MessageBox(
         "AstroBlink does not appear to be installed.\n\n" +
         "Install from the Mac App Store or download from:\n" +
         "https://github.com/joergs-git/AstroBlinkV2\n\n" +
         "You can still use this script if you have a CSV export.",
         SCRIPT_NAME, StdIcon_Information, StdButton_Ok
      );
      msg.execute();
   }

   var dialog = new AstroBlinkImporterDialog();
   dialog.execute();

   Console.writeln("---");
   Console.writeln(SCRIPT_NAME + " finished.");
}

main();
