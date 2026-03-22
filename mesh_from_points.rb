# mesh_from_points - TIN mesh from DXF/DWG topo (arcs + elevation text)
# Loader

require 'sketchup'

unless file_loaded?(__FILE__)
  ext = SketchupExtension.new('Mesh from Points', 'mesh_from_points/main')
  ext.description = 'Create triangulated mesh from DXF/DWG topo (arcs/polylines + elevation labels)'
  ext.version = '1.0.0'
  ext.creator = 'DWG-mesh'
  Sketchup.register_extension(ext, true)
  file_loaded(__FILE__)
end
