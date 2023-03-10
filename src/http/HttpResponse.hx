package http;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Encoding;

class HttpResponse {
    public var httpStatus:Int;
    public var headers:Map<String, Any>;

    public var originalRequest:HttpRequest;

    private var buffer:BytesBuffer = null;

    public function new() {
    }

    public var body(get, set):Bytes;
    private function get_body():Bytes {
        if (buffer == null) {
            return null;
        }
        return buffer.getBytes();
    }
    private function set_body(value:Bytes):Bytes {
        buffer = new BytesBuffer();
        buffer.addBytes(value, 0, value.length);
        return value;
    }

    public function write(data:String, encoding:Encoding = null) {
        if (buffer == null) {
            buffer = new BytesBuffer();
        }
        buffer.addString(data, encoding);
    }

    public var bodyAsString(get, null):String;
    private function get_bodyAsString():String {
        if (body == null) {
            return null;
        }

        return body.toString();
    }

    public var bodyAsJson(get, null):Dynamic;
    private function get_bodyAsJson():Dynamic {
        if (body == null) {
            return null;
        }

        return Json.parse(body.toString());
    }
}