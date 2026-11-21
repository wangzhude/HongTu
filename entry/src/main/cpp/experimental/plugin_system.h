/**
 * HongTu EDA - Plugin System + Batch Mode
 * Extensible plugin architecture:
 * - Plugin registration/discovery/lifecycle
 * - Menu extension points
 * - Custom tool registration
 * - File format handler registration
 * - Batch mode: headless DRC/LVS/format conversion
 */
#ifndef HONGTU_PLUGIN_SYSTEM_H
#define HONGTU_PLUGIN_SYSTEM_H

#include "scene_graph.h"
#include "drc_engine.h"
#include "lvs_engine.h"
#include "script_engine.h"
#include "image_export.h"
#include "format_readers.h"
#include <string>
#include <vector>
#include <functional>
#include <unordered_map>
#include <memory>
#include <fstream>
#include <sstream>

namespace hongtu {

// ==================== Plugin Interface ====================

enum class PluginType {
    FILE_FORMAT,    // Custom file reader/writer
    TOOL,           // Custom editing tool
    MENU_ACTION,    // Menu extension
    DRC_RULES,      // Custom DRC ruleset provider
    PCELL_LIB,      // PCell library
    EXPORT_FORMAT,  // Custom export format
    SCRIPT_COMMAND  // Custom script command
};

struct PluginInfo {
    std::string id;
    std::string name;
    std::string version;
    std::string author;
    std::string description;
    PluginType type;
    bool enabled;
};

/**
 * Plugin: Base class for all plugins.
 */
class Plugin {
public:
    virtual ~Plugin() = default;

    virtual PluginInfo info() const = 0;
    virtual bool initialize(Layout& layout) { return true; }
    virtual void shutdown() {}
    virtual void onLayoutLoaded(Layout& layout) {}
    virtual void onLayoutModified(Layout& layout) {}
};

// File format plugin
class FileFormatPlugin : public Plugin {
public:
    virtual std::vector<std::string> supportedExtensions() const = 0;
    virtual GdsiiParseResult readFile(const std::string& filePath) = 0;
    virtual bool writeFile(const Layout& layout, const std::string& filePath) = 0;
};

// Tool plugin
class ToolPlugin : public Plugin {
public:
    virtual std::string toolName() const = 0;
    virtual std::string shortcut() const { return ""; }
    virtual void onActivate(Layout& layout) {}
    virtual void onDeactivate() {}
    virtual void onMouseDown(double x, double y, Layout& layout) {}
    virtual void onMouseMove(double x, double y, Layout& layout) {}
    virtual void onMouseUp(double x, double y, Layout& layout) {}
};

// Menu action plugin
class MenuActionPlugin : public Plugin {
public:
    virtual std::string menuPath() const = 0;  // e.g., "Tools/My Action"
    virtual std::string shortcut() const { return ""; }
    virtual void execute(Layout& layout) = 0;
};

// ==================== Plugin Manager ====================

class PluginManager {
public:
    static PluginManager& instance() {
        static PluginManager mgr;
        return mgr;
    }

    void registerPlugin(std::shared_ptr<Plugin> plugin) {
        auto info = plugin->info();
        plugins_[info.id] = plugin;
    }

    void unregisterPlugin(const std::string& id) {
        auto it = plugins_.find(id);
        if (it != plugins_.end()) {
            it->second->shutdown();
            plugins_.erase(it);
        }
    }

    void enablePlugin(const std::string& id, bool enable) {
        auto it = plugins_.find(id);
        if (it != plugins_.end()) {
            // Plugin enabled/disabled state managed externally
        }
    }

    std::vector<PluginInfo> listPlugins() const {
        std::vector<PluginInfo> result;
        for (const auto& [id, plugin] : plugins_) {
            result.push_back(plugin->info());
        }
        return result;
    }

    std::shared_ptr<Plugin> findPlugin(const std::string& id) const {
        auto it = plugins_.find(id);
        return (it != plugins_.end()) ? it->second : nullptr;
    }

    // Find file format handler by extension
    std::shared_ptr<FileFormatPlugin> findFormatHandler(const std::string& ext) const {
        for (const auto& [id, plugin] : plugins_) {
            if (plugin->info().type == PluginType::FILE_FORMAT) {
                auto fmtPlugin = std::dynamic_pointer_cast<FileFormatPlugin>(plugin);
                if (fmtPlugin) {
                    auto exts = fmtPlugin->supportedExtensions();
                    for (const auto& e : exts) {
                        if (e == ext) return fmtPlugin;
                    }
                }
            }
        }
        return nullptr;
    }

    // Get all menu actions
    std::vector<std::shared_ptr<MenuActionPlugin>> menuActions() const {
        std::vector<std::shared_ptr<MenuActionPlugin>> result;
        for (const auto& [id, plugin] : plugins_) {
            if (plugin->info().type == PluginType::MENU_ACTION) {
                auto menuPlugin = std::dynamic_pointer_cast<MenuActionPlugin>(plugin);
                if (menuPlugin) result.push_back(menuPlugin);
            }
        }
        return result;
    }

    void notifyLayoutLoaded(Layout& layout) {
        for (auto& [id, plugin] : plugins_) {
            plugin->onLayoutLoaded(layout);
        }
    }

    void notifyLayoutModified(Layout& layout) {
        for (auto& [id, plugin] : plugins_) {
            plugin->onLayoutModified(layout);
        }
    }

private:
    PluginManager() = default;
    std::unordered_map<std::string, std::shared_ptr<Plugin>> plugins_;
};

// ==================== Batch Mode ====================

/**
 * BatchProcessor: Headless command-line processing.
 * Supports: DRC, LVS, format conversion, image export, script execution.
 */
class BatchProcessor {
public:
    struct BatchOptions {
        std::string inputFile;
        std::string outputFile;
        std::string operation;    // "drc", "lvs", "convert", "export", "script"
        std::string rulesetFile;  // For DRC
        std::string netlistFile;  // For LVS
        std::string scriptFile;   // For script execution
        std::string exportFormat; // "svg", "ppm", "gds", "oas"
        bool verbose = false;
    };

    struct BatchResult {
        bool success;
        std::string message;
        int violationCount;
        double executionTimeMs;
    };

    static BatchResult process(const BatchOptions& opts) {
        BatchResult result;
        result.success = false;
        result.violationCount = 0;

        auto startTime = std::chrono::high_resolution_clock::now();

        // Load input file
        Layout layout;
        if (!loadFile(layout, opts.inputFile)) {
            result.message = "Failed to load: " + opts.inputFile;
            return result;
        }

        if (opts.verbose) {
            auto stats = layout.getStats();
            std::cout << "Loaded: " << stats.totalShapes << " shapes, "
                     << stats.totalCells << " cells, "
                     << stats.totalLayers << " layers\n";
        }

        // Execute operation
        if (opts.operation == "drc") {
            result = runBatchDrc(layout, opts);
        } else if (opts.operation == "lvs") {
            result = runBatchLvs(layout, opts);
        } else if (opts.operation == "convert") {
            result = runBatchConvert(layout, opts);
        } else if (opts.operation == "export") {
            result = runBatchExport(layout, opts);
        } else if (opts.operation == "script") {
            result = runBatchScript(layout, opts);
        } else {
            result.message = "Unknown operation: " + opts.operation;
        }

        auto endTime = std::chrono::high_resolution_clock::now();
        result.executionTimeMs = std::chrono::duration<double, std::milli>(endTime - startTime).count();

        return result;
    }

private:
    static bool loadFile(Layout& layout, const std::string& filePath) {
        std::string ext = filePath.substr(filePath.find_last_of('.') + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        GdsiiParseResult parseResult;

        if (ext == "gds" || ext == "gds2" || ext == "gdsii") {
            GdsiiReader reader;
            parseResult = reader.parse(filePath);
        } else if (ext == "oas" || ext == "oasis") {
            OasisReaderV2 reader;
            parseResult = reader.parse(filePath);
        } else if (ext == "dxf") {
            DxfReader reader;
            parseResult = reader.parse(filePath);
        } else if (ext == "lef") {
            LefReader reader;
            parseResult = reader.parse(filePath);
        } else if (ext == "def") {
            DefReader reader;
            parseResult = reader.parse(filePath);
        } else if (ext == "cif") {
            CifReader reader;
            parseResult = reader.parse(filePath);
        } else {
            // Try plugin handlers
            auto handler = PluginManager::instance().findFormatHandler(ext);
            if (handler) {
                parseResult = handler->readFile(filePath);
            } else {
                return false;
            }
        }

        if (!parseResult.success) return false;

        // Populate layout from parse result
        layout.libName = parseResult.libName;
        layout.dbUnit = parseResult.databaseUnit;
        layout.userUnit = parseResult.userUnit;

        for (const auto& cell : parseResult.cells) {
            layout.addCell(cell.name);
        }

        for (const auto& s : parseResult.shapes) {
            SceneShape shape;
            shape.id = s.id;
            shape.layerKey = {(int16_t)s.layer, (int16_t)s.datatype};
            shape.ownerCellId = s.cellId;
            shape.pathWidth = s.pathWidth;
            shape.text = s.text;

            if (s.type == "rect") shape.type = ShapeType::RECT;
            else if (s.type == "polygon") shape.type = ShapeType::POLYGON;
            else if (s.type == "path") shape.type = ShapeType::PATH;
            else if (s.type == "text") shape.type = ShapeType::TEXT;
            else if (s.type == "instance") shape.type = ShapeType::INSTANCE;
            else shape.type = ShapeType::POLYGON;

            for (const auto& p : s.points) {
                shape.points.push_back({p.x, p.y});
            }
            layout.addShape(shape);
        }

        layout.resolveTopCell();
        layout.rebuildSpatialIndex();
        return true;
    }

    static BatchResult runBatchDrc(Layout& layout, const BatchOptions& opts) {
        BatchResult result;
        DrcEngine engine;

        // Load ruleset
        DrcRuleset ruleset = create28nmRuleset();  // Default
        // TODO: Load from opts.rulesetFile if specified

        engine.setRuleset(ruleset);
        auto violations = engine.run(layout);

        result.violationCount = (int)violations.size();
        result.success = true;
        result.message = "DRC complete: " + std::to_string(violations.size()) + " violations";

        // Write results to output file
        if (!opts.outputFile.empty()) {
            std::ofstream out(opts.outputFile);
            if (out.is_open()) {
                out << "# HongTu DRC Results\n";
                out << "# Input: " << opts.inputFile << "\n";
                out << "# Violations: " << violations.size() << "\n\n";
                for (const auto& v : violations) {
                    out << v.ruleId << " | " << v.message
                       << " | (" << v.x << ", " << v.y << ")"
                       << " | L" << v.layer << "/" << v.datatype << "\n";
                }
            }
        }

        return result;
    }

    static BatchResult runBatchLvs(Layout& layout, const BatchOptions& opts) {
        BatchResult result;
        LvsEngine lvs;

        std::string netlist;
        if (!opts.netlistFile.empty()) {
            std::ifstream f(opts.netlistFile);
            if (f.is_open()) {
                std::ostringstream ss;
                ss << f.rdbuf();
                netlist = ss.str();
            }
        }

        auto lvsResult = lvs.compare(layout, netlist);
        result.success = lvsResult.matched;
        result.message = lvsResult.matched ? "LVS PASS" : "LVS FAIL";

        if (!opts.outputFile.empty()) {
            std::string spice = lvs.exportSpice(layout);
            std::ofstream out(opts.outputFile);
            if (out.is_open()) out << spice;
        }

        return result;
    }

    static BatchResult runBatchConvert(Layout& layout, const BatchOptions& opts) {
        BatchResult result;
        result.success = false;

        if (opts.outputFile.empty()) {
            result.message = "No output file specified";
            return result;
        }

        std::string ext = opts.outputFile.substr(opts.outputFile.find_last_of('.') + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        // GDSII export (reuse existing ArkTS export logic concept)
        if (ext == "svg") {
            result.success = SvgExporter::saveToFile(layout, opts.outputFile);
        } else if (ext == "ppm" || ext == "png") {
            result.success = PngExporter::saveAsPpm(layout, opts.outputFile);
        } else {
            result.message = "Unsupported output format: " + ext;
        }

        if (result.success) {
            result.message = "Converted to: " + opts.outputFile;
        }
        return result;
    }

    static BatchResult runBatchExport(Layout& layout, const BatchOptions& opts) {
        return runBatchConvert(layout, opts);
    }

    static BatchResult runBatchScript(Layout& layout, const BatchOptions& opts) {
        BatchResult result;

        std::string script;
        if (!opts.scriptFile.empty()) {
            std::ifstream f(opts.scriptFile);
            if (!f.is_open()) {
                result.message = "Cannot open script: " + opts.scriptFile;
                return result;
            }
            std::ostringstream ss;
            ss << f.rdbuf();
            script = ss.str();
        }

        ScriptEngine engine;
        auto scriptResult = engine.execute(script, layout);

        result.success = scriptResult.success;
        result.message = scriptResult.output;
        return result;
    }
};

} // namespace hongtu

#endif // HONGTU_PLUGIN_SYSTEM_H
