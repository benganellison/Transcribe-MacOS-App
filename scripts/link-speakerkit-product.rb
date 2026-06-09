#!/usr/bin/env ruby
# One-off: link the SpeakerKit product into the Transcribe target.
#
# The existing "WhisperKit" package (github.com/argmaxinc/WhisperKit.git, tracking `main`)
# is now the argmax-oss-swift umbrella and already vends a SpeakerKit product — it's just
# not linked, so SpeakerKit symbols are undefined at link time. This adds the product
# dependency (and its Frameworks build-phase entry) against that SAME package reference.
# It does NOT add a second package (which would duplicate WhisperKit).
#
# Requires: gem install xcodeproj
# Run from the repo root:  ruby scripts/link-speakerkit-product.rb
# Idempotent. Safe to re-run. Restore with: git checkout -- Transcribe.xcodeproj/project.pbxproj

require 'xcodeproj'

proj = 'Transcribe.xcodeproj'
project = Xcodeproj::Project.open(proj)
target  = project.targets.find { |t| t.name == 'Transcribe' } or abort('✗ Transcribe target not found')
root    = project.root_object

# Find the existing package reference whose URL points at argmaxinc/WhisperKit.
pkg = root.package_references.find do |r|
  r.respond_to?(:repository_url) && r.repository_url.to_s.include?('argmaxinc/WhisperKit')
end
abort('✗ WhisperKit (argmax-oss-swift) package reference not found') unless pkg
puts "Using package: #{pkg.repository_url}"

if target.package_product_dependencies.any? { |d| d.product_name == 'SpeakerKit' && d.package == pkg }
  puts 'SpeakerKit product already linked — nothing to do.'
else
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'SpeakerKit'
  target.package_product_dependencies << dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file

  project.save
  puts '✓ linked SpeakerKit product into Transcribe target; saved project.'
end
