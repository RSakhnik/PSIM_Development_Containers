using System.Net.WebSockets;
var app=WebApplication.CreateBuilder(args).Build();
app.UseWebSockets();
app.MapGet("/headers",(HttpContext context)=>Results.Json(new{host=context.Request.Host.Value,forwardedHost=context.Request.Headers["X-Forwarded-Host"].ToString(),proto=context.Request.Headers["X-Forwarded-Proto"].ToString()}));
app.Map("/ws",async context=>{
 if(!context.WebSockets.IsWebSocketRequest){context.Response.StatusCode=400;await context.Response.WriteAsync("Upgrade missing");return;}
 using var socket=await context.WebSockets.AcceptWebSocketAsync();
 var buffer=new byte[4096];
 while(socket.State==WebSocketState.Open){var result=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),context.RequestAborted);if(result.MessageType==WebSocketMessageType.Close){await socket.CloseAsync(WebSocketCloseStatus.NormalClosure,"done",context.RequestAborted);break;}await socket.SendAsync(new ArraySegment<byte>(buffer,0,result.Count),result.MessageType,result.EndOfMessage,context.RequestAborted);}
});
app.Run();
