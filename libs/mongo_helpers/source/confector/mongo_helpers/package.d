module confector.mongo_helpers;

/**
 * The MongoDB driver shared by the Mongo backends (the document store and the dispatch queue),
 * so they depend on one driver version through this package.
 */
public import kaleidic.mongo_standalone;
