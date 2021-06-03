using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace RendererFeatures
{
    public class AScatteringRenderPass : ScriptableRenderPass
    {
        string profilerTag;

        Material materialToBlit;
        RenderTargetIdentifier cameraColorTargetIdent;
        RenderTargetHandle tempTexture;
        float scatteringStrength;
        private Vector3 wavelengths;
        
        public AScatteringRenderPass(string profilerTag, RenderPassEvent renderPassEvent, Material materialToBlit, float scatteringStrength, Vector3 wavelengths)
        {
            this.profilerTag = profilerTag;
            this.renderPassEvent = renderPassEvent;
            this.materialToBlit = materialToBlit;
            this.scatteringStrength = scatteringStrength;
            this.wavelengths = wavelengths;
        }

        // This isn't part of the ScriptableRenderPass class and is our own addition.
        // For this custom pass we need the camera's color target, so that gets passed in.
        public void Setup(RenderTargetIdentifier cameraColorTargetIdent)
        {
            this.cameraColorTargetIdent = cameraColorTargetIdent;
        }
        
        // This method is called before executing the render pass.
        // It can be used to configure render targets and their clear state. Also to create temporary render target textures.
        // When empty this render pass will render to the active camera render target.
        // You should never call CommandBuffer.SetRenderTarget. Instead call <c>ConfigureTarget</c> and <c>ConfigureClear</c>.
        // The render pipeline will ensure target setup and clearing happens in a performant manner.
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            // var light = GameObject.FindObjectOfType<Light>();
            // materialToBlit.SetVector("sunDirection", (light.transform.position - new Vector3(0,0,0)).normalized);
            
            float scatterX = Mathf.Pow(400 / wavelengths.x, 4);
            float scatterY = Mathf.Pow (400 / wavelengths.y, 4);
            float scatterZ = Mathf.Pow (400 / wavelengths.z, 4);
            materialToBlit.SetVector ("scatteringCoefficients", new Vector3 (scatterX, scatterY, scatterZ) * scatteringStrength);
        }

        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            // create a temporary render texture that matches the camera
            cmd.GetTemporaryRT(tempTexture.id, cameraTextureDescriptor);
        }
        // Here you can implement the rendering logic.
        // Use <c>ScriptableRenderContext</c> to issue drawing commands or execute command buffers
        // https://docs.unity3d.com/ScriptReference/Rendering.ScriptableRenderContext.html
        // You don't have to call ScriptableRenderContext.submit, the render pipeline will call it at specific points in the pipeline.
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // fetch a command buffer to use
            CommandBuffer cmd = CommandBufferPool.Get(profilerTag);
            cmd.Clear();

            
            // the actual content of our custom render pass!
            // we apply our material while blitting to a temporary texture
            cmd.Blit(cameraColorTargetIdent, tempTexture.Identifier(), materialToBlit, 0);

            // ...then blit it back again 
            cmd.Blit(tempTexture.Identifier(), cameraColorTargetIdent);

            // don't forget to tell ScriptableRenderContext to actually execute the commands
            context.ExecuteCommandBuffer(cmd);

            // tidy up after ourselves
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        // // called after Execute, use it to clean up anything allocated in Configure
        // public override void FrameCleanup(CommandBuffer cmd)
        // {
        //     cmd.ReleaseTemporaryRT(tempTexture.id);
        // }
        
        // Cleanup any allocated resources that were created during the execution of this render pass.
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(tempTexture.id);
        }
    }
    
}