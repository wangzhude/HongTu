#ifndef HONGTU_LAYOUT_PORT_H
#define HONGTU_LAYOUT_PORT_H
#include <string>
#include <vector>
namespace hongtu {
struct LayoutPort {
    std::string id, ownerCellKey, name;
    int ownerCellId = -1;
    double xNm = 0, yNm = 0, orientationDeg = 0, widthNm = 0;
    int layerNumber = 0, datatype = 0;
    std::string portType;
    bool frameMirror = false;
    double frameMagnification = 1;
    std::string crossSectionKey;
    int crossSectionVersion = 0;
    std::string infoJson = "{}", provenance;
};
struct LayoutCrossSection {
    std::string key; int version = 1;
    std::string name, definitionJson, sourceFormat, sourceVersion;
};
}
#endif
