# RideClimbPRO Build 26 + Climb3D

- RideClimbPRO remains the only source of truth.
- GPX is imported once by RideClimbPRO.
- GPXRoute now retains latitude/longitude so the same route builds the 3D mesh.
- RideModel.distanceM directly drives the red 3D marker and follow camera.
- RideModel.currentGradePercent is the displayed live grade.
- 3D road coloring uses GPXRoute.terrainGrade(), which is the same forward-grade algorithm/horizon used by RideModel.
- No separate Climb3D progress timer or point-to-point grade derivative.
- New "3D" tab.
- Build number: 26.
