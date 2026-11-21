#ifndef HONGTU_LAYOUT_IMPORT_BUDGET_H
#define HONGTU_LAYOUT_IMPORT_BUDGET_H
#include "gdsii_reader.h"
#include "native_import_estimate.h"
#include <algorithm>
#include <functional>
#include <stdexcept>

namespace hongtu {
/** Bound interactive hierarchy expansion before the active document is replaced.
 * Cost includes empty placements and nested array products, without enumeration. */
inline void ValidateInteractiveImportBudget(const GdsiiParseResult& parsed, const NativeJobControl* control = nullptr) {
    const auto estimate = EstimateInteractiveImport(parsed, control);
    if (!estimate.withinBudget) throw std::runtime_error(estimate.message);
}

}
#endif
