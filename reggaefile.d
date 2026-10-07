import reggae;
import reggae.config: options, configToDubInfo;
import reggae.rules.dub.runtime: dubBuild, dubTest;

// Main Confector DUB build target
Target confector() {
    auto opts = options.dup;
    if (opts.dubObjsDir == "")
        opts.dubObjsDir = "objs";
    return dubBuild(opts, configToDubInfo, Configuration("default"), CompilationMode.all);
}

// Optional unit test target
Target test() {
    auto opts = options.dup;
    if (opts.dubObjsDir == "")
        opts.dubObjsDir = "objs";
    return dubTest(opts, configToDubInfo, CompilationMode.all);
}

mixin build!(confector, optional!test);
