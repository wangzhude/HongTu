/** Independent A/B comparison. Coordinates are nm; filled regions are compared on an explicit grid. */
#ifndef HONGTU_LAYOUT_COMPARE_H
#define HONGTU_LAYOUT_COMPARE_H
#include <map>
#include <set>
#include <sstream>
#include <iomanip>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <cmath>
#include "layout_context.h"
#include "scene_graph.h"
#include "gdsii_reader.h"
#include "layout_import_budget.h"
#include "clipper_engine.h"
#include "native_job_control.h"

namespace hongtu {
struct LayoutCompareOptions {
    std::string cellA, cellB;
    double offsetX = 0, offsetY = 0;
    double gridNm = 0; // 0 chooses the finer database grid of A and B.
};
struct LayoutCompareLayer {
    int layerNumber = 0, datatype = 0;
    double areaOnlyA = 0, areaOnlyB = 0, xorArea = 0;
    BBox bounds;
    std::vector<std::vector<Vec2>> contours;
    size_t contourCount = 0;
    bool previewTruncated = false;
};
struct LayoutStructureDifference {
    std::string cellName, category;
    size_t onlyInA = 0, onlyInB = 0;
};
struct LayoutCompareResult {
    bool success = false, complete = false, geometryEqual = false, structureEqual = false;
    std::string errorMessage, cellA, cellB;
    double gridNm = 1, elapsedMs = 0;
    size_t comparedLayers = 0;
    std::vector<LayoutCompareLayer> layers;
    std::vector<LayoutStructureDifference> structureDifferences;
};
namespace compare_detail {
using Pair = std::pair<int,int>;
using Regions = std::map<Pair, clipper::Paths>;
inline void field(std::ostringstream& s, const std::string& value) { s << value.size() << ':' << value << ';'; }
inline std::string properties(const std::vector<LayoutProperty>& values, const NativeJobControl* control = nullptr) {
    std::vector<std::string> sorted;
    for (const auto& p : values) {
        if (control) control->check();
        std::ostringstream s; s << p.attr << ',' << int(p.dtype) << ';';
        field(s,p.name); field(s,p.value); sorted.push_back(s.str());
    }
    std::sort(sorted.begin(),sorted.end());
    std::ostringstream result; for (const auto& s : sorted) field(result,s); return result.str();
}
inline std::string cellName(const GdsiiParseResult& p, int id) {
    return id >= 0 && size_t(id) < p.cells.size() ? p.cells[size_t(id)].name : "<unresolved>";
}
inline std::string record(const GdsiiParseResult& p, const LayoutShape& shape, const NativeJobControl* control = nullptr) {
    std::ostringstream s; s << std::setprecision(17);
    field(s,shape.type); s << shape.layerNumber << ',' << shape.datatype << ';';
    for (const auto& v : shape.points) { if (control) control->check(); s << v.x << ',' << v.y << ';'; }
    s << '|' << shape.pathWidth << ',' << shape.pathType << ',' << shape.pathBeginExtension << ','
      << shape.pathEndExtension << ',' << shape.pathWidthAbsolute << ';';
    field(s,shape.text); s << shape.textPresentation << ';';
    if (shape.type == "instance") field(s,shape.cellId >= 0 ? cellName(p,shape.cellId) : shape.cellName);
    s << shape.rotation << ',' << shape.mirror << ',' << shape.magnification << ','
      << shape.arrayCols << ',' << shape.arrayRows << ',' << shape.arrayColStepX << ','
      << shape.arrayColStepY << ',' << shape.arrayRowStepX << ',' << shape.arrayRowStepY << ';';
    field(s,properties(shape.properties,control)); return s.str();
}
using Records = std::map<std::pair<std::string,std::string>,std::map<std::string,size_t>>;
// Metadata is compared as stored, rather than through a serializer/parser which
// could drop optional fields, reorder dictionaries, coerce types or round numbers.
// The file readers/edit model validate typed JSON; unknown raw context is opaque.
// No duplicate copy or hash of a potentially large context string is constructed.
inline bool strictBytes(const std::string& a,const std::string& b,const NativeJobControl* control) {
    if(control) control->check();
    if(a.size()!=b.size()) return false;
    constexpr size_t block=4096;
    for(size_t i=0;i<a.size();i+=block) {
        if(control) control->check();
        if(std::memcmp(a.data()+i,b.data()+i,std::min(block,a.size()-i))!=0) return false;
    }
    return true;
}
inline bool strictNumber(double a,double b) {
    static_assert(sizeof(double)==sizeof(uint64_t),"Comparison requires binary64 doubles");
    uint64_t aa=0,bb=0; std::memcpy(&aa,&a,sizeof(a)); std::memcpy(&bb,&b,sizeof(b));
    return aa==bb; // Includes the sign of zero; no tolerance/quantization here.
}
inline void metadataBudget(const GdsiiParseResult& p,const NativeJobControl* control,const std::string& stage) {
    if(!p.cellContextRecords.empty()&&p.cellContextRecords.size()!=p.cells.size())
        throw std::runtime_error("Comparison Cell context table does not match the complete Cell table");
    if(!p.cellKeys.empty()&&p.cellKeys.size()!=p.cells.size())
        throw std::runtime_error("Comparison Cell keys do not match the complete Cell table");
    if(p.cellKeys.empty()&&(!p.ports.empty()||!p.crossSections.empty()))
        throw std::runtime_error("Comparison typed metadata requires stable Cell keys");
    if(p.ports.size()>100000||p.crossSections.size()>4096)
        throw std::runtime_error("Comparison Port/CrossSection count budget exceeded");
    size_t bytes=0;
    const uint64_t total=1+p.cellContextRecords.size()+p.cellKeys.size()+p.ports.size()+p.crossSections.size();
    uint64_t done=0; if(control) control->report(stage,0,total);
    auto text=[&](const std::string& value,size_t limit=layout_context::kMaxBytes) {
        if(control) control->check();
        if(value.size()>limit||value.size()>layout_context::kMaxBytes-bytes)
            throw std::runtime_error("Comparison semantic/context string byte budget exceeded (64 MiB combined)");
        bytes+=value.size();
    };
    auto rows=[&](const std::vector<std::string>& values) {
        if(values.size()>layout_context::kMaxRecords) throw std::runtime_error("Comparison context record count budget exceeded");
        for(const auto& value:values) text(value,layout_context::kMaxStringBytes);
    };
    auto tick=[&]() { ++done; if(control&&(done%256==0||done==total)) control->report(stage,done,total); };
    rows(p.layoutContextRecords); tick();
    for(const auto& group:p.cellContextRecords) { rows(group); tick(); }
    for(const auto& key:p.cellKeys) { text(key,512); tick(); }
    for(const auto& xs:p.crossSections) {
        text(xs.key,512); text(xs.name,512); text(xs.definitionJson,256u*1024u);
        text(xs.sourceFormat); text(xs.sourceVersion); tick();
    }
    for(const auto& port:p.ports) {
        text(port.id,512); text(port.ownerCellKey,512); text(port.name,512); text(port.portType,128);
        text(port.crossSectionKey,512); text(port.infoJson,64u*1024u); text(port.provenance,64u*1024u);
        if(port.ownerCellId<0||size_t(port.ownerCellId)>=p.cells.size()||
            !strictBytes(port.ownerCellKey,p.cellKeys[size_t(port.ownerCellId)],control))
            throw std::runtime_error("Comparison Port owner/key is inconsistent with the Cell table");
        for(double n:{port.xNm,port.yNm,port.orientationDeg,port.widthNm,port.frameMagnification})
            if(!std::isfinite(n)) throw std::runtime_error("Comparison contains a nonfinite typed Port number");
        tick();
    }
}
inline bool strictPort(const LayoutPort& a,const LayoutPort& b,const NativeJobControl* control) {
    return strictBytes(a.id,b.id,control)&&strictBytes(a.ownerCellKey,b.ownerCellKey,control)&&
        strictBytes(a.name,b.name,control)&&a.ownerCellId==b.ownerCellId&&
        strictNumber(a.xNm,b.xNm)&&strictNumber(a.yNm,b.yNm)&&strictNumber(a.orientationDeg,b.orientationDeg)&&
        strictNumber(a.widthNm,b.widthNm)&&a.layerNumber==b.layerNumber&&a.datatype==b.datatype&&
        strictBytes(a.portType,b.portType,control)&&a.frameMirror==b.frameMirror&&
        strictNumber(a.frameMagnification,b.frameMagnification)&&
        strictBytes(a.crossSectionKey,b.crossSectionKey,control)&&a.crossSectionVersion==b.crossSectionVersion&&
        strictBytes(a.infoJson,b.infoJson,control)&&strictBytes(a.provenance,b.provenance,control);
}
inline bool strictSection(const LayoutCrossSection& a,const LayoutCrossSection& b,const NativeJobControl* control) {
    return strictBytes(a.key,b.key,control)&&a.version==b.version&&strictBytes(a.name,b.name,control)&&
        strictBytes(a.definitionJson,b.definitionJson,control)&&strictBytes(a.sourceFormat,b.sourceFormat,control)&&
        strictBytes(a.sourceVersion,b.sourceVersion,control);
}
// Counts are unmatched ordered records, not a multiset. Moving a record changes
// its stored position. Keys and Cell context also include their owning Cell name.
inline void metadata(const GdsiiParseResult& a,const GdsiiParseResult& b,LayoutCompareResult& out,const NativeJobControl* control) {
    uint64_t done=0,total=std::max(a.cellKeys.size(),b.cellKeys.size())+
        std::max(a.ports.size(),b.ports.size())+std::max(a.crossSections.size(),b.crossSections.size())+
        std::max(a.layoutContextRecords.size(),b.layoutContextRecords.size())+
        std::max(a.cellContextRecords.size(),b.cellContextRecords.size());
    if(control) control->report("metadata_diff",0,total);
    auto tick=[&]() { if(control) { control->check(); if(++done%256==0||done==total) control->report("metadata_diff",done,total); } };
    auto ordered=[&](const auto& aa,const auto& bb,const std::string& category,const auto& equal) {
        size_t na=0,nb=0;
        for(size_t i=0;i<std::max(aa.size(),bb.size());++i) {
            if(control) control->check();
            const bool hasA=i<aa.size(),hasB=i<bb.size();
            if(!hasA||!hasB||!equal(i)) { if(hasA) ++na; if(hasB) ++nb; }
            tick();
        }
        if(na||nb) out.structureDifferences.push_back({"<library>",category,na,nb});
    };
    ordered(a.cellKeys,b.cellKeys,"stable-cell-key",[&](size_t i) {
        return strictBytes(a.cells[i].name,b.cells[i].name,control)&&strictBytes(a.cellKeys[i],b.cellKeys[i],control);
    });
    ordered(a.ports,b.ports,"typed-port",[&](size_t i) {
        const auto& aa=a.ports[i]; const auto& bb=b.ports[i];
        return strictBytes(a.cells[size_t(aa.ownerCellId)].name,b.cells[size_t(bb.ownerCellId)].name,control)&&strictPort(aa,bb,control);
    });
    ordered(a.crossSections,b.crossSections,"cross-section",[&](size_t i) { return strictSection(a.crossSections[i],b.crossSections[i],control); });
    ordered(a.layoutContextRecords,b.layoutContextRecords,"layout-context",[&](size_t i) {
        return strictBytes(a.layoutContextRecords[i],b.layoutContextRecords[i],control);
    });
    ordered(a.cellContextRecords,b.cellContextRecords,"cell-context",[&](size_t i) {
        if(!strictBytes(a.cells[i].name,b.cells[i].name,control)) return false;
        const auto& aa=a.cellContextRecords[i]; const auto& bb=b.cellContextRecords[i];
        if(aa.size()!=bb.size()) return false;
        for(size_t row=0;row<aa.size();++row) if(!strictBytes(aa[row],bb[row],control)) return false;
        return true;
    });
    if(control) control->report("metadata_diff",total,total);
}
inline Records records(const GdsiiParseResult& p, const NativeJobControl* control = nullptr, const std::string& stage = "structure") {
    Records result;
    const uint64_t total = 1 + p.cells.size() + p.shapes.size(); uint64_t done = 0;
    if (control) control->report(stage,done,total);
    result[{"<library>","properties"}][properties(p.libProperties,control)]++; ++done;
    for (const auto& c : p.cells) {
        if (control) control->check();
        result[{c.name,"cell"}][properties(c.properties,control)]++; ++done;
    }
    for (const auto& shape : p.shapes) {
        if (control) control->check();
        const std::string category = shape.type == "instance" ? "instance" :
            shape.type == "text" ? "text" : shape.type == "node" ? "node" : "geometry-record";
        result[{cellName(p,shape.ownerCellId),category}][record(p,shape,control)]++;
        if (control && (++done % 1024 == 0)) control->report(stage,done,total);
    }
    if (control) control->report(stage,total,total);
    return result;
}
inline void structure(const GdsiiParseResult& a,const GdsiiParseResult& b,LayoutCompareResult& out, const NativeJobControl* control = nullptr) {
    auto ra=records(a,control,"structure_A"), rb=records(b,control,"structure_B");
    std::set<std::pair<std::string,std::string>> keys;
    for(const auto& v:ra) { if(control) control->check(); keys.insert(v.first); }
    for(const auto& v:rb) { if(control) control->check(); keys.insert(v.first); }
    uint64_t done=0; if(control) control->report("structure_diff",0,keys.size());
    for(const auto& key:keys) {
        if(control) control->check();
        auto& aa=ra[key]; auto& bb=rb[key]; size_t na=0,nb=0;
        for(const auto& v:aa) { if(control) control->check(); const auto it=bb.find(v.first); const size_t n=it==bb.end()?0:it->second; if(v.second>n) na+=v.second-n; }
        for(const auto& v:bb) { if(control) control->check(); const auto it=aa.find(v.first); const size_t n=it==aa.end()?0:it->second; if(v.second>n) nb+=v.second-n; }
        if(na||nb) out.structureDifferences.push_back({key.first,key.second,na,nb});
        if(control) control->report("structure_diff",++done,keys.size());
    }
    if(a.physicalUnits!=b.physicalUnits || a.userUnits!=b.userUnits)
        out.structureDifferences.push_back({"<library>","units",1,1});
    if(a.libName!=b.libName) out.structureDifferences.push_back({"<library>","name",1,1});
    metadata(a,b,out,control);
    out.structureEqual=out.structureDifferences.empty();
}
inline int root(const Layout& layout,const std::string& name) {
    if(name.empty()) return layout.topCellId();
    for(const auto& c:layout.cells) if(c.name==name) return c.id;
    throw std::runtime_error("Comparison Cell not found: "+name);
}
inline Regions regions(const Layout& layout,int cell,double grid,double ox,double oy,
    const NativeJobControl* control = nullptr,const std::string& suffix = "A") {
    if(!layout.findCell(cell)) throw std::runtime_error("Comparison needs a valid top Cell");
    Regions result; size_t total=0,shapes=0;
    layout.flattenHierarchy(cell,-1,[&](const SceneShape& shape,const GeometryEngine::Transform2D& xf) {
        if(control) control->check();
        if(++shapes>1000000) throw std::runtime_error("Comparison exceeds one million expanded shapes");
        if(shape.type==ShapeType::TEXT || shape.type==ShapeType::NODE) return;
        const auto vertices=effectivePolygonTransformed(shape,xf);
        if(vertices.size()<3) throw std::runtime_error("Comparison contains a degenerate filled shape");
        total+=vertices.size(); if(total>8000000) throw std::runtime_error("Comparison exceeds eight million vertices");
        clipper::Path path;
        for(const auto& v:vertices) {
            if(control) control->check();
            const double x=(v.x+ox)/grid,y=(v.y+oy)/grid;
            if(!std::isfinite(x)||!std::isfinite(y)||std::abs(x)>clipper::GeneralClipper::kCoordLimit||std::abs(y)>clipper::GeneralClipper::kCoordLimit)
                throw std::runtime_error("Comparison coordinate exceeds grid range");
            path.push_back({int64_t(std::llround(x)),int64_t(std::llround(y))});
        }
        // Separate source shapes use independent fill semantics, not XOR cancellation.
        result[{shape.layerKey.layer,shape.layerKey.datatype}].push_back(std::move(path));
        if(control && shapes%1024==0) control->report("hierarchy_"+suffix,shapes,0);
    },nullptr,nullptr,control ? control->checkpoint : std::function<void()>{});
    uint64_t done=0;
    if(control) control->report("union_"+suffix,0,result.size());
    for(auto& item:result) {
        if(control) control->check();
        auto merged=clipper::GeneralClipper::unite(item.second,control ? control->checkpoint : std::function<void()>{});
        if(merged.approximated||merged.droppedRings) throw std::runtime_error("Comparison region rejected: "+merged.note);
        item.second=std::move(merged.contours);
        if(control) control->report("union_"+suffix,++done,result.size());
    }
    return result;
}
inline double area(const clipper::Paths& paths,double grid,const NativeJobControl* control = nullptr) {
    long double sum=0;
    for(const auto& p:paths) {
        if(control) control->check();
        if(p.size()<3) continue;
        // Subtract a local origin before multiplication. Unlike the adapter's
        // integer area helper this preserves large legal regions without
        // saturating int64, and keeps holes' signed areas intact.
        const long double ox=p.front().x,oy=p.front().y;
        for(size_t i=1;i+1<p.size();++i) {
            if(control) control->check();
            const long double ax=static_cast<long double>(p[i].x)-ox;
            const long double ay=static_cast<long double>(p[i].y)-oy;
            const long double bx=static_cast<long double>(p[i+1].x)-ox;
            const long double by=static_cast<long double>(p[i+1].y)-oy;
            sum+=ax*by-ay*bx;
        }
    }
    return static_cast<double>(std::abs(sum)*0.5L*grid*grid);
}
inline clipper::Paths difference(const clipper::Paths& a,const clipper::Paths& b,clipper::ClipType op,const NativeJobControl* control = nullptr) {
    auto result=clipper::GeneralClipper::executeNZ(a,b,op,control ? control->checkpoint : std::function<void()>{});
    if(result.approximated||result.droppedRings) throw std::runtime_error("Comparison boolean rejected: "+result.note);
    return std::move(result.contours);
}
}
inline LayoutCompareResult CompareLayouts(const GdsiiParseResult& pa,const Layout& a,
    const GdsiiParseResult& pb,const Layout& b,const LayoutCompareOptions& options,const NativeJobControl* control = nullptr) {
    LayoutCompareResult result;
    try {
        ValidateInteractiveImportBudget(pa,control); ValidateInteractiveImportBudget(pb,control);
        compare_detail::metadataBudget(pa,control,"metadata_validate_A");
        compare_detail::metadataBudget(pb,control,"metadata_validate_B");
        for(const auto* parsed:{&pa,&pb}) {
            std::set<std::string> names;
            for(const auto& cell:parsed->cells) { if(control) control->check(); if(!names.insert(cell.name).second) throw std::runtime_error("Comparison contains duplicate Cell names"); }
            for(const auto& shape:parsed->shapes) {
                if(control) control->check();
                if(shape.ownerCellId<0||size_t(shape.ownerCellId)>=parsed->cells.size()) throw std::runtime_error("Comparison contains a shape without valid owner Cell");
                if(shape.type=="instance"&&(shape.cellId<0||size_t(shape.cellId)>=parsed->cells.size())) throw std::runtime_error("Comparison contains an unresolved instance");
            }
        }
        if(!std::isfinite(options.offsetX)||!std::isfinite(options.offsetY)) throw std::runtime_error("Alignment offset must be finite");
        if(!std::isfinite(options.gridNm)||options.gridNm<0)
            throw std::runtime_error("Comparison grid must be finite and nonnegative; zero selects automatic grid");
        result.gridNm=options.gridNm>0?options.gridNm:std::min(pa.physicalUnits,pb.physicalUnits)*1e9;
        if(!std::isfinite(result.gridNm)||result.gridNm<1e-6||result.gridNm>1000000)
            throw std::runtime_error("Comparison grid must be between 0.000001 and 1000000 nm");
        const int rootA=compare_detail::root(a,options.cellA),rootB=compare_detail::root(b,options.cellB);
        result.cellA=compare_detail::cellName(pa,rootA); result.cellB=compare_detail::cellName(pb,rootB);
        if(control) control->report("hierarchy_A",0,0);
        auto ra=compare_detail::regions(a,rootA,result.gridNm,0,0,control,"A");
        if(control) control->report("hierarchy_B",0,0);
        auto rb=compare_detail::regions(b,rootB,result.gridNm,options.offsetX,options.offsetY,control,"B");
        std::set<compare_detail::Pair> keys;
        for(const auto& p:ra) { if(control) control->check(); keys.insert(p.first); }
        for(const auto& p:rb) { if(control) control->check(); keys.insert(p.first); }
        result.comparedLayers=keys.size(); size_t previewVertices=0;
        uint64_t done=0;
        for(const auto& key:keys) {
            if(control) control->report("geometry_diff",done,keys.size());
            auto delta=compare_detail::difference(ra[key],rb[key],clipper::ClipType::XOR,control);
            if(delta.empty()) { ++done; continue; }
            LayoutCompareLayer layer; layer.layerNumber=key.first; layer.datatype=key.second;
            layer.xorArea=compare_detail::area(delta,result.gridNm,control);
            layer.areaOnlyA=compare_detail::area(compare_detail::difference(ra[key],rb[key],clipper::ClipType::DIFFERENCE,control),result.gridNm,control);
            layer.areaOnlyB=compare_detail::area(compare_detail::difference(rb[key],ra[key],clipper::ClipType::DIFFERENCE,control),result.gridNm,control);
            layer.contourCount=delta.size();
            for(const auto& ring:delta) {
                if(control) control->check();
                std::vector<Vec2> contour;
                for(const auto& v:ring) {
                    if(control) control->check();
                    const double x=v.x*result.gridNm,y=v.y*result.gridNm;
                    layer.bounds=layer.bounds.unite(BBox(x,y,x,y));
                    if(previewVertices+ring.size()<=50000) contour.push_back({x,y});
                }
                if(contour.size()==ring.size()) { previewVertices+=ring.size(); layer.contours.push_back(std::move(contour)); }
                else layer.previewTruncated=true;
            }
            // Never paint an outer ring without its omitted hole. Bounds remain available.
            if(layer.previewTruncated) layer.contours.clear();
            result.layers.push_back(std::move(layer));
            ++done;
        }
        if(control) control->report("geometry_diff",keys.size(),keys.size());
        compare_detail::structure(pa,pb,result,control);
        if(control) control->check();
        result.geometryEqual=result.layers.empty(); result.success=true; result.complete=true;
    } catch(const NativeJobCancelled&) { throw; }
    catch(const std::exception& e) {
        result.errorMessage=e.what(); result.success=false; result.complete=false;
        result.geometryEqual=false; result.structureEqual=false; result.layers.clear(); result.structureDifferences.clear();
    }
    return result;
}
}
#endif
