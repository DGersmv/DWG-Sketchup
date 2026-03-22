# Topo Mesh - mesh from imported DWG/DXF by isolines
# Loader

require 'sketchup'

unless file_loaded?(__FILE__)
  ext = SketchupExtension.new('Topo Mesh', 'mesh_from_points/main')
  ext.description = 'Create topo mesh from imported DWG/DXF. Import via File > Import, select component, build mesh by isolines.'
  ext.version = '3.0.0'
  ext.creator = 'DWG-mesh'
  Sketchup.register_extension(ext, true)
  file_loaded(__FILE__)
end
