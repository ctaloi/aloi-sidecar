.pragma library

// One meetings service per shell. The bar widget finds it through the shell's
// plugin services; this is the fallback when that lookup isn't available.
var service = null

function set(s) { service = s }
function get() { return service }
function clear(s) { if (service === s) service = null }
