module controller.admin_controller;

import vibe.vibe;
import vibe.core.log : logInfo, logError, logWarn;
import confector.core.plugin : PluginRegistry, Plugin;
import confector.core.plugin_loader : PluginLoader, LoadedPluginRecord, PluginLoadException;
import std.uri : encodeComponent;
import std.string : strip;

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
        ulong executorProvidersCount = reg.getExecutorProviders().length;

        string errorMessage = req.query.get("error", "");
        string successMessage = req.query.get("success", "");

        res.render!("admin/plugins.dt", plugins, dynamicCount, stepSystemsCount, executorProvidersCount, errorMessage, successMessage);
    });

    router.post("/admin/plugins/load", (HTTPServerRequest req, HTTPServerResponse res) {
        auto plLoader = loader !is null ? loader : PluginLoader.instance;
        string libPath = req.form.get("libraryPath", "").strip;

        if (libPath.length == 0)
        {
            res.redirect("/admin/plugins?error=" ~ encodeComponent("Plugin library path cannot be empty"));
            return;
        }

        try
        {
            auto loadedPlugin = plLoader.loadPlugin(libPath);
            logInfo("Admin dynamically loaded plugin '%s' from '%s'", loadedPlugin.name, libPath);
            res.redirect("/admin/plugins?success=" ~ encodeComponent("Successfully loaded plugin " ~ loadedPlugin.name));
        }
        catch (Exception e)
        {
            logError("Failed to dynamically load plugin from '%s': %s", libPath, e.msg);
            res.redirect("/admin/plugins?error=" ~ encodeComponent("Failed to load plugin: " ~ e.msg));
        }
    });

    router.post("/admin/plugins/unload", (HTTPServerRequest req, HTTPServerResponse res) {
        auto plLoader = loader !is null ? loader : PluginLoader.instance;
        string pluginName = req.form.get("pluginName", "").strip;

        if (pluginName.length == 0)
        {
            res.redirect("/admin/plugins?error=" ~ encodeComponent("Plugin name cannot be empty"));
            return;
        }

        try
        {
            plLoader.unloadPlugin(pluginName);
            logInfo("Admin unloaded plugin '%s'", pluginName);
            res.redirect("/admin/plugins?success=" ~ encodeComponent("Successfully unloaded plugin " ~ pluginName));
        }
        catch (Exception e)
        {
            logError("Failed to unload plugin '%s': %s", pluginName, e.msg);
            res.redirect("/admin/plugins?error=" ~ encodeComponent("Failed to unload plugin: " ~ e.msg));
        }
    });

    return router;
}
