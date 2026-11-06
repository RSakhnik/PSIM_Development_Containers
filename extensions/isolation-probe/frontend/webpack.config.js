const path = require('path');
const ModuleFederationPlugin = require('webpack/lib/container/ModuleFederationPlugin');
module.exports = {
 entry: {main:'./src/index.ts'},
 module:{rules:[{test:/\.tsx?$/,use:'ts-loader',exclude:/node_modules/}]},
 resolve:{extensions:['.ts','.js']},
 output:{path:path.resolve(__dirname,'dist'),publicPath:'auto',uniqueName:'pilot_environment_isolation_probe',scriptType:'text/javascript',filename:'[name].[contenthash].js',chunkFilename:'[id].[contenthash].js',clean:true},
 optimization:{runtimeChunk:false},
 plugins:[new ModuleFederationPlugin({name:'pilot_environment_isolation_probe',library:{type:'var',name:'pilot_environment_isolation_probe'},filename:'pilot_environment_isolation_probe.'+process.env.ISOLATION_PROBE_MARKER+'.js',exposes:{'IToolbar<ObjectsViewContext>':'./src/probe.ts'},shared:{'@pilotdev/pilot-web-sdk':{singleton:true,import:false,requiredVersion:'26.19.0'}}})]
};
