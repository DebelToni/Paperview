import {build} from 'esbuild';
await build({entryPoints:['index.mjs'],bundle:true,format:'iife',globalName:'BoardTextTools',platform:'neutral',target:'es2020',outfile:'../../Paperview/Board/Resources/text-tools.js',legalComments:'eof',define:{process:'undefined'}});
