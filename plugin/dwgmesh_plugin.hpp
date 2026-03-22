// Copyright 2025 DWG-mesh Plugin. SketchUp importer for DXF/DWG topo.

#ifndef DWGMESH_PLUGIN_HPP
#define DWGMESH_PLUGIN_HPP

#include <SketchUpAPI/import_export/modelimporterplugin.h>
#include "../common/dwg_options.hpp"

class CDwgMeshPlugin : public SketchUpModelImporterInterface {
 public:
  std::string GetIdentifier() const override {
    return "com.sketchup.importers.dwgmesh";
  }

  int GetFileExtensionCount() const override {
    return 2;
  }

  std::string GetFileExtension(int index) const override {
    return index == 0 ? "dxf" : "dwg";
  }

  std::string GetDescription() const override;

  bool SupportsOptions() const override {
    return false;
  }

  bool SupportsProgress() const override {
    return true;
  }

  bool ConvertToSkp(
      const std::string& input, const std::string& output_skp,
      SketchUpPluginProgressCallback* callback, void* reserved) override;

  void SetOptions(const DwgOptions& opts) { options_ = opts; }
  const DwgOptions& GetOptions() const { return options_; }

 private:
  DwgOptions options_;
};

#endif  // DWGMESH_PLUGIN_HPP
