#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. Ordinary users open the checked-in project."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(name, body):
    key = ident(name)
    objects[key] = body
    return key

def q(text):
    return json.dumps(text, ensure_ascii=False)

def refs(values):
    return '(' + ', '.join(values) + (',' if values else '') + ')'

base = obj('base-config', 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Base.xcconfig; sourceTree = "<group>";')
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
groups, products, targets = [], [], []
for app, product, sdk, settings in [
    ('MacApp', 'WristControl', 'macosx', {
        'MACOSX_DEPLOYMENT_TARGET': '13.0', 'PRODUCT_BUNDLE_IDENTIFIER': '$(WRIST_BUNDLE_PREFIX).mac',
        'INFOPLIST_FILE': 'Config/Mac-Info.plist', 'CODE_SIGN_ENTITLEMENTS': 'Config/Mac.entitlements',
        'ENABLE_APP_SANDBOX': 'YES', 'SUPPORTED_PLATFORMS': 'macosx',
    }),
    ('WatchApp', 'WristWatch', 'watchos', {
        'WATCHOS_DEPLOYMENT_TARGET': '9.0', 'PRODUCT_BUNDLE_IDENTIFIER': '$(WRIST_BUNDLE_PREFIX).watch',
        'INFOPLIST_FILE': 'Config/Watch-Info.plist', 'TARGETED_DEVICE_FAMILY': '4',
        'SUPPORTED_PLATFORMS': 'watchos watchsimulator', 'SKIP_INSTALL': 'NO',
    }),
]:
    files, builds = [], []
    for path in sorted((ROOT / app).glob('*.swift')):
        ref = obj(str(path.relative_to(ROOT)), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path.name)}; sourceTree = "<group>";')
        files.append(ref)
        builds.append(obj('build-' + app + path.name, f'isa = PBXBuildFile; fileRef = {ref};'))
    groups.append(obj(app, f'isa = PBXGroup; children = {refs(files)}; path = {app}; sourceTree = "<group>";'))
    product_ref = obj('product-' + app, f'isa = PBXFileReference; explicitFileType = wrapper.application; path = {product}.app; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product_ref)
    dependency = obj('core-' + app, f'isa = XCSwiftPackageProductDependency; package = {package}; productName = WristCore;')
    link = obj('link-' + app, f'isa = PBXBuildFile; productRef = {dependency};')
    sources = obj('sources-' + app, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    frameworks = obj('frameworks-' + app, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({link},); runOnlyForDeploymentPostprocessing = 0;')
    resources = obj('resources-' + app, 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    configs = []
    for configuration in ['Debug', 'Release']:
        config_settings = {'SDKROOT': sdk, 'PRODUCT_NAME': product, 'GENERATE_INFOPLIST_FILE': 'NO',
                           'ONLY_ACTIVE_ARCH': 'YES' if configuration == 'Debug' else 'NO',
                           'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if configuration == 'Debug' else '-O', **settings}
        setting_body = ' '.join(f'{k} = {q(v)};' for k, v in config_settings.items())
        configs.append(obj(app + configuration, f'isa = XCBuildConfiguration; baseConfigurationReference = {base}; buildSettings = {{ {setting_body} }}; name = {configuration};'))
    configlist = obj('configs-' + app, f'isa = XCConfigurationList; buildConfigurations = {refs(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    target = obj('target-' + app, f'isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({sources}, {frameworks}, {resources},); buildRules = (); dependencies = (); name = {product}; packageProductDependencies = ({dependency},); productName = {product}; productReference = {product_ref}; productType = "com.apple.product-type.application";')
    targets.append(target)
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}.app" BlueprintName="{product}" ReferencedContainer="container:WristControl.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}.app" BlueprintName="{product}" ReferencedContainer="container:WristControl.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    scheme_dir = ROOT / 'WristControl.xcodeproj/xcshareddata/xcschemes'
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / f'{product}.xcscheme').write_text(scheme)

product_group = obj('products', f'isa = PBXGroup; children = {refs(products)}; name = Products; sourceTree = "<group>";')
main_group = obj('root', f'isa = PBXGroup; children = {refs(groups + [base, product_group])}; sourceTree = "<group>";')
project_configs = [obj('project-' + c, f'isa = XCBuildConfiguration; buildSettings = {{}}; name = {c};') for c in ['Debug', 'Release']]
project_configlist = obj('project-configs', f'isa = XCConfigurationList; buildConfigurations = {refs(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }}; buildConfigurationList = {project_configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, zh_CN, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; packageReferences = ({package},); targets = {refs(targets)};')
body = '\n'.join(f'\t\t{k} = {{ {v} }};' for k, v in objects.items())
text = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + body + '\n\t};\n\trootObject = ' + project + ';\n}\n'
(ROOT / 'WristControl.xcodeproj/project.pbxproj').write_text(text)
print('Generated WristControl.xcodeproj (Mac + standalone Watch + local WristCore package).')
