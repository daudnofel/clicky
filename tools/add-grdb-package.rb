#!/usr/bin/env ruby
# Adds the GRDB.swift SwiftPM package dependency to the leanring-buddy
# target. Run from the fork root: `ruby tools/add-grdb-package.rb`.
#
# Idempotent — re-running is safe; it will detect an existing package
# reference and skip the add.

require "xcodeproj"

PROJECT_PATH = "leanring-buddy.xcodeproj"
PACKAGE_URL  = "https://github.com/groue/GRDB.swift"
PACKAGE_PRODUCT_NAME = "GRDB"  # the library product exported by the package
MIN_VERSION  = "6.0.0"         # "Up to Next Major" floor

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == "leanring-buddy" }
raise "could not find leanring-buddy target" unless app_target

# Check whether GRDB is already referenced.
existing = project.root_object.package_references.find do |ref|
  ref.repositoryURL == PACKAGE_URL
end

if existing
  puts "GRDB.swift package reference already present — skipping add."
else
  puts "Adding GRDB.swift package reference ..."
  package_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package_ref.repositoryURL = PACKAGE_URL
  package_ref.requirement = {
    "kind"    => "upToNextMajorVersion",
    "minimumVersion" => MIN_VERSION,
  }
  project.root_object.package_references << package_ref

  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.package = package_ref
  product_dep.product_name = PACKAGE_PRODUCT_NAME

  app_target.package_product_dependencies << product_dep

  # Also need a PBXBuildFile referencing the product so it gets linked
  # into the app target.
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  frameworks_phase = app_target.frameworks_build_phase
  frameworks_phase.files << build_file
end

project.save
puts "Saved project."
