library;

export 'src/configurator.dart'
    show
        Configurator,
        GeneratedFile,
        ConfigurationPlan,
        FileChange,
        DirectoryChange,
        recoverConfiguration;
export 'src/manifest.dart' show BrandManifest, ManifestFile, supportedPlatforms;
export 'src/template.dart' show renderTemplate, encodeTemplateValue;
