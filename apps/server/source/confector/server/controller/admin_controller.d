module confector.server.controller.admin_controller;

import vibe.vibe;
import confector.core.plugin : PluginRegistry, Plugin;
import confector.core.plugin_loader : PluginLoader, LoadedPluginRecord;

struct PluginViewModel
{
    string name;
    string versionString;
    string description;
    bool isDynamic;
    bool isBundled;
    string path;
}

URLRouter adminRouter(PluginRegistry registry, PluginLoader loader = null)
{
    auto router = new URLRouter();

    router.get("/admin", (HTTPServerRequest req, HTTPServerResponse res) {
        res.redirect("/admin/plugins");
    });
    router.get("/admin/", (HTTPServerRequest req, HTTPServerResponse res) {
        res.redirect("/admin/plugins");
    });

    router.get("/admin/plugins", (HTTPServerRequest req, HTTPServerResponse res) {
        auto reg = registry !is null ? registry : PluginRegistry.instance;
        auto plLoader = loader !is null ? loader : PluginLoader.instance;

        auto allPlugins = reg.allPlugins();
        auto loadedRecords = plLoader.loadedPlugins;

        PluginViewModel[] plugins;
        ulong dynamicCount = 0;

        foreach (p; allPlugins)
        {
            PluginViewModel vm;
            vm.name = p.name;
            vm.versionString = p.versionString;
            vm.description = p.description;

            if (auto rec = p.name in loadedRecords)
            {
                vm.isDynamic = true;
                vm.isBundled = rec.isBundled;
                vm.path = rec.path;
                dynamicCount++;
            }
            else
            {
                vm.isDynamic = false;
                vm.isBundled = false;
                vm.path = "";
            }
            plugins ~= vm;
        }

        ulong stepSystemsCount = reg.getStepSystems().length;
        ulong executorProvidersCount = reg.getComputeProviders().length;

        // Read-only: plugins are loaded only from server configuration at startup.
        res.render!("admin/plugins.dt", plugins, dynamicCount, stepSystemsCount, executorProvidersCount);
    });

    return router;
}
