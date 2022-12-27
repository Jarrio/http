package http;

import queues.NonQueue;
import queues.IQueue;
import http.HttpMethod;
import haxe.Timer;
import logging.LogManager;
import logging.Logger;
import http.HttpRequest;
import promises.Promise;
import http.providers.DefaultHttpProvider;
import queues.IQueue;
import queues.NonQueue;

class HttpClient {
    private var log:Logger = new Logger(HttpClient);

    public var followRedirects:Bool = true;
    public var retryCount:Null<Int> = 3;
    public var retryDelayMs:Int = 1000;
    public var defaultRequestHeaders:Map<String, Any>;

    public var requestTransformers:Array<IHttpRequestTransformer>;
    public var responseTransformers:Array<IHttpResponseTransformer>;

    public function new() {
    }

    private var _requestQueueProvider:Class<IQueue<RequestQueueItem>> = null;
    public var requestQueueProvider(get, set):Class<IQueue<RequestQueueItem>>;
    private function get_requestQueueProvider():Class<IQueue<RequestQueueItem>> {
        if (_requestQueueProvider == null) {
            _requestQueueProvider = NonQueue;
        }
        return _requestQueueProvider;
    }
    private function set_requestQueueProvider(value:Class<IQueue<RequestQueueItem>>):Class<IQueue<RequestQueueItem>> {
        _requestQueueProvider = value;
        return value;
    }

    private var _requestQueue:IQueue<RequestQueueItem> = null;
    private var requestQueue(get, null):IQueue<RequestQueueItem>;
    private function get_requestQueue():IQueue<RequestQueueItem> {
        if (_requestQueue != null) {
            return _requestQueue;
        }

        _requestQueue = Type.createInstance(requestQueueProvider, []);
        _requestQueue.onMessage = onQueueMessage;
        return _requestQueue;
    }

    private var _provider:IHttpProvider = null;
    public var provider(get, set):IHttpProvider;
    private function get_provider():IHttpProvider {
        if (_provider == null) {
            _provider = new DefaultHttpProvider();
        }
        return _provider;
    }
    private function set_provider(value:IHttpProvider):IHttpProvider {
        _provider = value;
        return value;
    }

    public function get(request:HttpRequest, queryParams:Map<String, Any> = null, headers:Map<String, Any> = null):Promise<HttpResult> {
        request.method = HttpMethod.Get;
        return makeRequest(request, null, queryParams, headers);
    }

    public function post(request:HttpRequest, body:Any = null, queryParams:Map<String, Any> = null, headers:Map<String, Any> = null):Promise<HttpResult> {
        request.method = HttpMethod.Post;
        return makeRequest(request, body, queryParams, headers);
    }

    public function put(request:HttpRequest, body:Any = null, queryParams:Map<String, Any> = null, headers:Map<String, Any> = null):Promise<HttpResult> {
        request.method = HttpMethod.Put;
        return makeRequest(request, body, queryParams, headers);
    }

    public function delete(request:HttpRequest, body:Any = null, queryParams:Map<String, Any> = null, headers:Map<String, Any> = null):Promise<HttpResult> {
        request.method = HttpMethod.Delete;
        return makeRequest(request, body, queryParams, headers);
    }

    public function makeRequest(request:HttpRequest, body:Any = null, queryParams:Map<String, Any> = null, headers:Map<String, Any> = null):Promise<HttpResult> {
        var copy = request.clone();

        // query params
        var finalQueryParams:Map<String, Any> = null;
        if (copy.queryParams != null) {
            if (finalQueryParams == null) {
                finalQueryParams = [];
            }
            for (key in copy.queryParams.keys()) {
                finalQueryParams.set(key, copy.queryParams.get(key));
            }
        }
        if (queryParams != null) {
            if (finalQueryParams == null) {
                finalQueryParams = [];
            }
            for (key in queryParams.keys()) {
                finalQueryParams.set(key, queryParams.get(key));
            }
        }
        copy.queryParams = finalQueryParams;

        // headers
        var finalRequestHeaders:Map<String, Any> = defaultRequestHeaders;
        if (copy.headers != null) {
            if (finalRequestHeaders == null) {
                finalRequestHeaders = [];
            }
            for (key in copy.headers.keys()) {
                finalRequestHeaders.set(key, copy.headers.get(key));
            }
        }
        if (headers != null) {
            if (finalRequestHeaders == null) {
                finalRequestHeaders = [];
            }
            for (key in headers.keys()) {
                finalRequestHeaders.set(key, headers.get(key));
            }
        }
        copy.headers = finalRequestHeaders;

        // body
        if (body != null) {
            copy.body = body;
        }

        return new Promise((resolve, reject) -> {
            requestQueue.enqueue({
                retryCount: 0,
                request: copy,
                resolve: resolve,
                reject: reject
            });
        });
    }

    private function onQueueMessage(item:RequestQueueItem) {
        return new Promise((resolve, reject) -> {
            var request = item.request.clone();
            if (requestTransformers != null) {
                for (transformer in requestTransformers) {
                    transformer.process(request);
                }
            }

            log.info('making "${request.method.getName().toLowerCase()}" request to "${request.url.build()}"');
            provider.makeRequest(request).then(response -> {
                if (response != null) {
                    if (LogManager.instance.shouldLogDebug) {
                        log.debug('response received: ');
                        log.debug('    headers:', response.headers);
                        log.debug('    body:', response.bodyAsString);
                    } else {
                        log.info('response received (${response.httpStatus})');
                    }
                } else {
                    if (LogManager.instance.shouldLogWarnings) {
                        log.warn('null response received');
                    }
                }
                
                if (responseTransformers != null) {
                    for (transformer in responseTransformers) {
                        transformer.process(response);
                    }
                }
    
                // handle redirections by requeing the request with the new url
                if (followRedirects && response.httpStatus == 302) {
                    var redirectLocation:String = null;
                    if (response.headers != null) {
                        redirectLocation = response.headers.get("location");
                        if (redirectLocation == null) {
                            redirectLocation = response.headers.get("Location");
                        }
                    }

                    // we'll consider it an error if there is no location header
                    if (redirectLocation == null) {
                        log.error('redirect encountered (${response.httpStatus}), no location header found');
                        var httpError = new HttpError("no location header found", response.httpStatus);
                        httpError.body = response.body;
                        httpError.headers = response.headers;
                        item.reject(httpError);
                        resolve(true); // ack
                        return;
                    }

                    var queryParams = item.request.url.queryParams; // cache original queryParams from url
                    item.request.url = redirectLocation;
                    item.request.url.queryParams = queryParams;
                    item.retryCount = 0;
                    requestQueue.enqueue(item);
                    resolve(true); // ack
                    return;
                }

                item.resolve(new HttpResult(this, response));
                resolve(true); // ack
            }, (error:HttpError) -> {
                if (retryCount == null) {
                    log.error('request failed (${error.httpStatus})');
                    error.retryCount = 0;
                    item.reject(error); 
                } else {
                    item.retryCount++;
                    if (item.retryCount > retryCount) {
                        if (retryCount > 0) {
                            log.error('request failed (${error.httpStatus}), retries exhausted');
                            error.retryCount = item.retryCount - 1;
                        } else {
                            log.error('request failed (${error.httpStatus})');
                            error.retryCount = 0;
                        }
                        item.reject(error); 
                    } else {
                        log.error('request failed (${error.httpStatus}), retrying (${item.retryCount} of ${retryCount})');
                        if (retryDelayMs > 0) {
                            Timer.delay(() -> {
                                requestQueue.enqueue(item);
                            }, retryDelayMs);
                        } else {
                            requestQueue.enqueue(item);
                        }
                    }
                }
                resolve(true); // we are resolving true even though its an error as this is to tell the queue we have processed the message (ie, ack)
            });
        });
    }
}

typedef RequestQueueItem = {
    var retryCount:Int;
    var request:HttpRequest;
    var resolve:HttpResult->Void;
    var reject:Dynamic->Void;
}