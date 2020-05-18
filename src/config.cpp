#include "config.h"
#include "common.h"
#include <fstream>
#include <iomanip>
#include <nlohmann/json.hpp>
#include <set>
using json = nlohmann::json;

#define add2json(v) j[#v] = v;
#define tryassign(v)                                                                     \
  try {                                                                                  \
    j.at(#v).get_to(v);                                                                  \
  } catch (exception & e) {}
#define merge(v)                                                                         \
  {                                                                                      \
    v.erase(std::remove(v.begin(), v.end(), v##_preserved), v.end());                    \
    v.insert(v.begin(), v##_preserved);                                                  \
  }

namespace CGPROXY::CONFIG {

void Config::toEnv() {
  mergeReserved();
  setenv("cgroup_proxy", join2str(cgroup_proxy, ':').c_str(), 1);
  setenv("cgroup_noproxy", join2str(cgroup_noproxy, ':').c_str(), 1);
  setenv("enable_gateway", to_str(enable_gateway).c_str(), 1);
  setenv("port", to_str(port).c_str(), 1);
  setenv("enable_dns", to_str(enable_dns).c_str(), 1);
  setenv("enable_tcp", to_str(enable_tcp).c_str(), 1);
  setenv("enable_udp", to_str(enable_udp).c_str(), 1);
  setenv("enable_ipv4", to_str(enable_ipv4).c_str(), 1);
  setenv("enable_ipv6", to_str(enable_ipv6).c_str(), 1);
}

int Config::saveToFile(const string f) {
  ofstream o(f);
  if (!o.is_open()) return FILE_ERROR;
  string js = toJsonStr();
  o << setw(4) << js << endl;
  o.close();
  return 0;
}

string Config::toJsonStr() {
  json j;
  add2json(cgroup_proxy);
  add2json(cgroup_noproxy);
  add2json(enable_gateway);
  add2json(port);
  add2json(enable_dns);
  add2json(enable_tcp);
  add2json(enable_udp);
  add2json(enable_ipv4);
  add2json(enable_ipv6);
  return j.dump();
}

int Config::loadFromFile(const string f) {
  debug("loading config: %s", f.c_str());
  ifstream ifs(f);
  if (ifs.is_open()) {
    string js = to_str(ifs.rdbuf());
    ifs.close();
    return loadFromJsonStr(js);
  } else {
    error("open failed: %s", f.c_str());
    return FILE_ERROR;
  }
}

int Config::loadFromJsonStr(const string js) {
  if (!validateJsonStr(js)) {
    error("json validate fail");
    return PARAM_ERROR;
  }
  json j = json::parse(js);
  tryassign(cgroup_proxy);
  tryassign(cgroup_noproxy);
  tryassign(enable_gateway);
  tryassign(port);
  tryassign(enable_dns);
  tryassign(enable_tcp);
  tryassign(enable_udp);
  tryassign(enable_ipv4);
  tryassign(enable_ipv6);
  return 0;
}

void Config::mergeReserved() {
  merge(cgroup_proxy);
  merge(cgroup_noproxy);
}

bool Config::validateJsonStr(const string js) {
  json j = json::parse(js);
  bool status = true;
  const set<string> boolset = {"enable_gateway", "enable_dns",  "enable_tcp",
                               "enable_udp",     "enable_ipv4", "enable_ipv6"};
  for (auto &[key, value] : j.items()) {
    if (key == "cgroup_proxy" || key == "cgroup_noproxy") {
      if (value.is_string() && !validCgroup((string)value)) status = false;
      // TODO what if vector<int> etc.
      if (value.is_array() && !validCgroup((vector<string>)value)) status = false;
      if (!value.is_string() && !value.is_array()) status = false;
    } else if (key == "port") {
      if (!validPort(value)) status = false;
    } else if (boolset.find(key) != boolset.end()) {
      if (!value.is_boolean()) status = false;
    } else {
      error("unknown key: %s", key.c_str());
      return false;
    }
    if (!status) {
      error("invalid value for key: %s", key.c_str());
      return false;
    }
  }
  return true;
}

} // namespace CGPROXY::CONFIG