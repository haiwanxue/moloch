/* lexical grammar */
%lex

%options flex
%%

\s+                        /* skip whitespace */
[-a-zA-Z0-9_.@:*?/]+       return 'STR'
\"[^"\\]*(?:\\.[^"\\]*)*\" return 'QUOTEDSTR'
\/[^/\\]*(?:\\.[^/\\]*)*\/ return 'REGEXSTR'
\[[^/\\]*(?:\\.[^/\\]*)*\] return 'LIST'
"EXISTS!"                  return "EXISTS"
"<="                       return 'lte'
"<"                        return 'lt'
">="                       return 'gte'
">"                        return 'gt'
"!="                       return '!='
"=="                       return '=='
"="                        return '=='
"||"                       return '||'
"|"                        return '||'
"&&"                       return '&&'
"&"                        return '&&'
"("                        return '('
")"                        return ')'
"!"                        return '!'
<<EOF>>                    return 'EOF'
.                          return 'INVALID'

/lex

/* operator associations and precedence */

%left '!'
%left '<' '<=' '>' '>=' '==' '!=' 
%left '||'
%left '&&'
%left UMINUS

%start expressions

%% /* language grammar */

expressions
    : e EOF
        { return $1; }
    ;

OP  : lt   {$$ = 'lt'}
    | lte  {$$ = 'lte'}
    | gt   {$$ = 'gt'}
    | gte  {$$ = 'gte'}
    | '==' {$$ = 'eq'}
    | '!=' {$$ = 'ne'}
    ;

VALUE : STR
      | QUOTEDSTR
      | REGEXSTR
      | LIST
      ;

 
e
    : e '&&' e
        {$$ = {bool: {must: [$1, $3]}};}
    | e '||' e
        {$$ = {bool: {should: [$1, $3]}};}
    | '!' e %prec UMINUS
        {$$ = {not: $2};}
    | '-' e %prec UMINUS
        {$$ = -$2;}
    | '(' e ')'
        {$$ = $2;}
    | STR '==' EXISTS
        {$$ = {exists: {field: field2Raw(yy, $1)}};}
    | STR '!=' EXISTS
        {$$ = {not: {exists: {field: field2Raw(yy, $1)}}};}
    | STR OP VALUE
        { $$ = formatQuery(yy, $1, $2, $3);
          //console.log(util.inspect($$, false, 50));
        }
    ;
%%

var    util           = require('util');

function parseIpPort(yy, field, ipPortStr) {
  var dbField = yy.fieldsMap[field].dbField;

  function singleIp(dbField, ip1, ip2, port) {
    var obj;

    if (ip1 !== -1) {
      if (ip1 === ip2) {
        obj = {term: {}};
        obj.term[dbField] = ip1>>>0;
      } else {
        obj = {range: {}};
        obj.range[dbField] = {from: ip1>>>0, to: ip2>>>0};
      }
    }

    if (port !== -1) {
      if (yy.fieldsMap[field].portField) {
        obj = {bool: {must: [obj, {term: {}}]}};
        obj.bool.must[1].term[yy.fieldsMap[field].portField] = port;
      } else {
        throw field + " doesn't support port";
      }

      if (ip1 === -1) {
        obj = obj.bool.must[1];
      }
    }

    return obj;
  }


  var obj;

  ipPortStr = ipPortStr.trim();

// We really have a list of them
  if (ipPortStr[0] === "[" && ipPortStr[ipPortStr.length -1] === "]") {
      obj =  {bool: {should: []}};
      CSVtoArray(ipPortStr).forEach(function(str) {
        obj.bool.should.push(parseIpPort(yy, field, str));
      });
      return obj;
  }

  // Support '10.10.10/16:4321'

  var ip1 = -1, ip2 = -1;
  var colons = ipPortStr.split(':');
  var slash = colons[0].split('/');
  var dots = slash[0].split('.');
  var port = -1;
  if (colons[1]) {
    port = parseInt(colons[1], 10);
  }

  if (dots.length === 4) {
    ip1 = ip2 = (parseInt(dots[0], 10) << 24) | (parseInt(dots[1], 10) << 16) | (parseInt(dots[2], 10) << 8) | parseInt(dots[3], 10);
  } else if (dots.length === 3) {
    ip1 = (parseInt(dots[0], 10) << 24) | (parseInt(dots[1], 10) << 16) | (parseInt(dots[2], 10) << 8);
    ip2 = (parseInt(dots[0], 10) << 24) | (parseInt(dots[1], 10) << 16) | (parseInt(dots[2], 10) << 8) | 255;
  } else if (dots.length === 2) {
    ip1 = (parseInt(dots[0], 10) << 24) | (parseInt(dots[1], 10) << 16);
    ip2 = (parseInt(dots[0], 10) << 24) | (parseInt(dots[1], 10) << 16) | (255 << 8) | 255;
  } else if (dots.length === 1 && dots[0].length > 0) {
    ip1 = (parseInt(dots[0], 10) << 24);
    ip2 = (parseInt(dots[0], 10) << 24) | (255 << 16) | (255 << 8) | 255;
  }

  // Can't shift by 32 bits in javascript, who knew!
  if (slash[1] && slash[1] !== '32') {
     var s = parseInt(slash[1], 10);
     ip1 = ip1 & (0xffffffff << (32 - s));
     ip2 = ip2 | (0xffffffff >>> s);
  }
  
  if (dbField !== "ipall") {
    return singleIp(dbField, ip1, ip2, port);
  }

  var ors = [];
  var completed = {};
  for (field in yy.fieldsMap) {
    var info = yy.fieldsMap[field];

    // If ip itself or not an ip field stop
    if (field === "ip" || info.type !== "ip")
      continue;

    // Already completed
    if (completed[info.dbField])
      continue;
    completed[info.dbField] = 1;

    // If port specified then skip ips without ports
    if (port !== -1 && !info.portField)
      continue;

    if (info.requiredRight && yy[info.requiredRight] !== true) {
      continue;
    }
    obj = singleIp(info.dbField, ip1, ip2, port);
    if (obj) {
      ors.push(obj);
    }
  }

  return {bool: {should: ors}};
}

function stripQuotes (str) {
  if (str[0] === "\"") {
    str =  str.substring(1, str.length-1);
  }
  return str;
}

function formatQuery(yy, field, op, value)
{
  var obj;
  //console.log("yy", util.inspect(yy, false, 50));

  if (!yy.fieldsMap[field])
    throw "Unknown field " + field;

  var info = yy.fieldsMap[field];

  if (info.requiredRight && yy[info.requiredRight] !== true) {
    throw field + " - permission denied";
  }

  if (info.regex) {
    var regex = new RegExp(info.regex);
    var obj = [];
    var completed = [];
    for (var f in yy.fieldsMap) {
      if (f.match(regex) && !completed[yy.fieldsMap[f].dbField]) {
        if (yy.fieldsMap[f].requiredRight && yy[yy.fieldsMap[f].requiredRight] !== true) {
          continue;
        }
        obj.push(formatQuery(yy, f, "eq", value));
        completed[yy.fieldsMap[f].dbField] = 1;
      }
    }
    if (op === "eq")
      return {bool: {should: obj}};
    if (op === "ne")
      return {bool: {must_not: obj}};
    throw "Invalid operator '" + op + "' for " + field;
  }

  switch (info.type) {
  case "ip":
    if (op === "eq")
      return parseIpPort(yy, field, value);
    if (op === "ne")
      return {not: parseIpPort(yy, field, value)};
    throw "Invalid operator '" + op + "' for ip";
  case "integer":
    if (value[0] === "/")
      throw value + " - Regex queries not supported for integer queries";

    if (op === "eq" || op === "ne") {
      obj = termOrTermsInt(info.dbField, value);
      if (op === "ne") {
        obj = {not: obj};
      }
      return obj;
    }

    if (value[0] === "\[")
      throw value + " - List queries not supported for gt/lt queries";

    obj = {range: {}};
    obj.range[info.dbField] = {};
    obj.range[info.dbField][op] = value;
    return obj;
  case "lotermfield":
  case "lotextfield":
    if (op === "eq")
      return stringQuery(yy, field, value.toLowerCase());
    if (op === "ne")
      return {not: stringQuery(yy, field, value.toLowerCase())};
    throw "Invalid operator '" + op + "' for " + field;
  case "termfield":
  case "textfield":
    if (op === "eq")
      return stringQuery(yy, field, value);
    if (op === "ne")
      return {not: stringQuery(yy, field, value)};
    throw "Invalid operator '" + op + "' for " + field;
  case "uptermfield":
  case "uptextfield":
    if (op === "eq")
      return stringQuery(yy, field, value.toUpperCase());
    if (op === "ne")
      return {not: stringQuery(yy, field, value.toUpperCase())};
    throw "Invalid operator '" + op + "' for " + field;
  case "fileand":
    if (value[0] === "\[")
      throw value + " - List queries not supported for file queries";

    if (op === "eq")
      return {fileand: stripQuotes(value)}
    if (op === "ne")
      return {not: {findand: stripQuotes(value)}};
    throw op + " - not supported for file queries";
    break;
  default:
    throw "Unknown field type: " + info.type;
  }
}

function field2Raw(yy, field) {
  var info = yy.fieldsMap[field];
  var dbField = info.dbField;
  if (info.rawField)
    return info.rawField;

  if (dbField.indexOf(".snow", dbField.length - 5) === 0)
    return dbField.substring(0, dbField.length - 5) + ".raw";

  return dbField;
}

function stringQuery(yy, field, str) {

  var info = yy.fieldsMap[field];
  var dbField = info.dbField;


  if (str[0] === "/" && str[str.length -1] === "/") {
    str = str.substring(1, str.length-1);
    if (info.transform) {
      str = global.moloch[info.transform](str).replace(/2e/g, '.');
    }
    dbField = field2Raw(yy, field);
    obj = {regexp: {}};
    obj.regexp[dbField] = str.replace(/\\(.)/g, "$1");
    return obj;
  }


  var quoted = false;
  if (str[0] === "\"" && str[str.length -1] === "\"") {
    str = str.substring(1, str.length-1).replace(/\\(.)/g, "$1");
    quoted = true;
  } else if (str[0] === "[" && str[str.length -1] === "]") {
    strs = CSVtoArray(str);
    if (info.transform) {
      for (var i = 0; i < strs.length; i++) {
        strs[i] = global.moloch[info.transform](strs[i]);
      }
    }

    if (info.type.match(/termfield/)) {
      obj = {terms: {}};
      obj.terms[dbField] = strs;
    } else if (info.type.match(/textfield/)) {
      var obj =  {query: {bool: {should: []}}};
      strs.forEach(function(str) {
        var should = {text: {}};
        should.text[dbField] = {query: str, type: "phrase", operator: "and"}
        obj.query.bool.should.push(should);
      });
    }
    return obj;
  }

  if (info.transform) {
    str = global.moloch[info.transform](str);
  }

  if (!isNaN(str) && !quoted) {
    obj = {term: {}};
    obj.term[dbField] = str;
  } else if (typeof str === "string" && str.indexOf("*") !== -1) {
    dbField = field2Raw(yy, field);
    obj = {query: {wildcard: {}}};
    obj.query.wildcard[dbField] = str;
  } else if (info.type.match(/textfield/)) {
    obj = {query: {text: {}}};
    obj.query.text[dbField] = {query: str, type: "phrase", operator: "and"}
  } else if (info.type.match(/termfield/)) {
    obj = {term: {}};
    obj.term[dbField] = str;
  }

  return obj;
}

if (!global.moloch) global.moloch = {};
global.moloch.utf8ToHex = function (utf8) {
    var hex = new Buffer(stripQuotes(utf8)).toString("hex").toLowerCase();
    hex = hex.replace(/2a/g, '*');
    return hex;
}

var protocols = {
    icmp: 1,
    tcp:  6,
    udp:  17
};

global.moloch.ipProtocolLookup = function (text) {
    if (typeof text !== "string") {
        for (var i = 0; i < text.length; i++) {
            text[i] = protocols[text[i]] || +text[i];
        }
        return text;
    } else {
        return protocols[text] || +text;
    }
};

// http://stackoverflow.com/a/8497474
// Return array of string values, or NULL if CSV string not well formed.
function CSVtoArray(text) {
  if (text[0] !== "[" || text[text.length -1] !== "]")
    return text;

    text = text.substring(1, text.length-1);
    var re_valid = /^\s*(?:'[^'\\]*(?:\\[\S\s][^'\\]*)*'|"[^"\\]*(?:\\[\S\s][^"\\]*)*"|[^,'"\s\\]*(?:\s+[^,'"\s\\]+)*)\s*(?:,\s*(?:'[^'\\]*(?:\\[\S\s][^'\\]*)*'|"[^"\\]*(?:\\[\S\s][^"\\]*)*"|[^,'"\s\\]*(?:\s+[^,'"\s\\]+)*)\s*)*$/;
    var re_value = /(?!\s*$)\s*(?:'([^'\\]*(?:\\[\S\s][^'\\]*)*)'|"([^"\\]*(?:\\[\S\s][^"\\]*)*)"|([^,'"\s\\]*(?:\s+[^,'"\s\\]+)*))\s*(?:,|$)/g;
    // Return NULL if input string is not well formed CSV string.
    if (!re_valid.test(text)) return null;
    var a = [];                     // Initialize array to receive values.
    text.replace(re_value, // "Walk" the string using replace with callback.
        function(m0, m1, m2, m3) {
            // Remove backslash from \' in single quoted values.
            if      (m1 !== undefined) a.push(m1.replace(/\\'/g, "'"));
            // Remove backslash from \" in double quoted values.
            else if (m2 !== undefined) a.push(m2.replace(/\\"/g, '"'));
            else if (m3 !== undefined) a.push(m3);
            return ''; // Return empty string.
        });
    // Handle special case of empty last value.
    if (/,\s*$/.test(text)) a.push('');
    return a;
};

function termOrTermsStr(dbField, str) {
  var obj = {};
  if (str[0] === "[" && str[str.length -1] === "]") {
    obj = {terms: {}};
    obj.terms[dbField] = CSVtoArray(str);
  } else {
    obj = {term: {}};
    obj.term[dbField] = str;
  }
  return obj;
}
function termOrTermsInt(dbField, str) {
  var obj = {};
  if (str[0] === "[" && str[str.length -1] === "]") {
    obj = {terms: {}};
    obj.terms[dbField] = CSVtoArray(str);
    obj.terms[dbField].forEach(function(str) {
      str = stripQuotes(str);
      if (typeof str !== "integer" && str.match(/[^\d]+/))
        throw str + " is not a number";
    });
  } else {
    str = stripQuotes(str);
    if (str.match(/[^\d]+/))
      throw str + " is not a number";
    obj = {term: {}};
    obj.term[dbField] = str;
  }
  return obj;
}
