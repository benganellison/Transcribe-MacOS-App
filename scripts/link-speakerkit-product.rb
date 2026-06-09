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

# Read the repository URL robustly across xcodeproj gem versions (accessor name varies).
def url_of(obj)
  h = (obj.to_hash rescue {})
  h['repositoryURL'] || h['repositoryUrl'] ||
    (obj.repository_url rescue nil) || (obj.repositoryURL rescue nil)
end

def product_name_of(dep)
  (dep.product_name rescue nil) || (dep.productName rescue nil) ||
    ((dep.to_hash['productName']) rescue nil)
end

refs = (root.package_references rescue [])
puts "package_references count: #{refs.size}"
refs.each_with_index { |r, i| puts "  [#{i}] #{r.isa}  url=#{url_of(r).inspect}" }

pkg = refs.find { |r| (url_of(r) || '').include?('argmaxinc/WhisperKit') } ||
      refs.find { |r| (url_of(r) || '').downcase.include?('argmax') }

unless pkg
  puts '✗ could not locate the WhisperKit/argmax package reference (see the list above).'
  puts '  Paste the list above and I will adjust the matcher.'
  exit 1
end
puts "Using package: #{url_of(pkg)}"

if target.package_product_dependencies.any? { |d| product_name_of(d) == 'SpeakerKit' && d.package == pkg }
  puts 'SpeakerKit product already linked — nothing to do.'
  exit 0
end

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = 'SpeakerKit'
target.package_product_dependencies << dep

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = dep
target.frameworks_build_phase.files << build_file

project.save
puts '✓ linked SpeakerKit product into Transcribe target; saved project.'
