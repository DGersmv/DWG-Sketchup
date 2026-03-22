// Copyright 2025 DWG-mesh Plugin. Exported importer interface.

#include "../plugin/dwgmesh_plugin.hpp"
#include <SketchUpAPI/import_export/modelimporterplugin.h>

// Singleton importer instance
static CDwgMeshPlugin g_importer;

SketchUpModelImporterInterface* GetSketchUpModelImporterInterface() {
  return &g_importer;
}
