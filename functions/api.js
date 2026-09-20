import { handleAPI } from '../server/api.js';
export function onRequest({request,env}) { return handleAPI(request,env); }
